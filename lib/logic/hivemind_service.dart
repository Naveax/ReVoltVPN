import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

enum SessionProbeResult {
  active,
  inactive,
  unavailable,
}

enum SessionStopResult {
  stopped,
  alreadyInactive,
  retryNeeded,
}

class HivemindService {
  static String? _sessionNonce;
  static int _currentCallId = 0;
  static final Random _secureRandom = Random.secure();
  static Future<SessionStopResult>? _stopInFlight;

  static const _ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  static const _sessionNonceHeader = 'X-RevoltVPN-Session-Nonce';
  static const int _maxControlResponseBytes = 256 * 1024;
  static const _pollBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
  ];

  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? headers,
  }) {
    return _controlRequest(
      'GET',
      uri,
      timeout: timeout,
      headers: headers,
    );
  }

  static Future<http.Response> directPost(
    Uri uri, {
    required String body,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? headers,
  }) {
    return _controlRequest(
      'POST',
      uri,
      timeout: timeout,
      headers: <String, String>{
        'Content-Type': 'application/json',
        ...?headers,
      },
      body: body,
    );
  }

  /// Control-plane requests never follow redirects, never leave the configured
  /// HTTPS origin, and never buffer an unbounded response body.
  static Future<http.Response> _controlRequest(
    String method,
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
    String? body,
  }) async {
    _validateApiUri(uri);

    final client = http.Client();
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(<String, String>{'User-Agent': _ua, ...?headers});
    if (body != null) request.body = body;

    Future<http.Response> read() async {
      final streamed = await client.send(request);
      final declaredLength = streamed.contentLength;
      if (declaredLength != null &&
          declaredLength > _maxControlResponseBytes) {
        throw const FormatException('Control response is too large.');
      }

      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        if (bytes.length + chunk.length > _maxControlResponseBytes) {
          throw const FormatException('Control response is too large.');
        }
        bytes.addAll(chunk);
      }

      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
        request: request,
      );
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          client.close();
          throw TimeoutException('Control request timed out.', timeout);
        },
      );
    } finally {
      client.close();
    }
  }

  static String newNonce() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static void cancel() {
    _currentCallId++;
  }

  static Future<void> setSessionNonce(String nonce) async {
    await CryptoService.setSessionNonce(nonce);
    _sessionNonce = nonce;
  }

  static Future<String?> getSessionNonce() async {
    if (_sessionNonce != null) return _sessionNonce;
    _sessionNonce = await CryptoService.getSessionNonce();
    return _sessionNonce;
  }

  static Future<void> clearSessionNonce() async {
    _sessionNonce = null;
    await CryptoService.clearSessionNonce();
    await CryptoService.clearSessionStopPending();
  }

  static Future<http.Response> authenticatedGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final nonce = await getSessionNonce();
    if (nonce == null) {
      throw Exception('Session authorization unavailable.');
    }
    return directGet(
      uri,
      timeout: timeout,
      headers: <String, String>{_sessionNonceHeader: nonce},
    );
  }

  /// Probe the persisted possession token without minting a replacement.
  /// Ambiguous network/server failures leave the token untouched so a possibly
  /// live server generation cannot be replaced with a fresh reward nonce.
  static Future<SessionProbeResult> probeCurrentSession() async {
    final nonce = await getSessionNonce();
    if (nonce == null) return SessionProbeResult.inactive;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final response = await directGet(
        _sessionStatusUrl(deviceId),
        timeout: const Duration(seconds: 3),
        headers: <String, String>{_sessionNonceHeader: nonce},
      );

      if (response.statusCode == 401) {
        await clearSessionNonce();
        return SessionProbeResult.inactive;
      }
      if (response.statusCode != 200) {
        return SessionProbeResult.unavailable;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return SessionProbeResult.unavailable;
      }

      if (data['active'] == true) {
        final serverNonce = data['nonce'];
        if (serverNonce != null &&
            (serverNonce is! String || serverNonce != nonce)) {
          return SessionProbeResult.unavailable;
        }
        return SessionProbeResult.active;
      }

      await clearSessionNonce();
      return SessionProbeResult.inactive;
    } catch (_) {
      return SessionProbeResult.unavailable;
    }
  }

  /// Commit a candidate main-session nonce only after the server projects that
  /// exact possession token as active.
  static Future<bool> confirmAndSetSessionNonce(String nonce) async {
    final deviceId = await CryptoService.getDeviceId();
    final url = _sessionStatusUrl(deviceId);

    const maxAttempts = 8;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await directGet(
          url,
          timeout: const Duration(seconds: 2),
          headers: <String, String>{_sessionNonceHeader: nonce},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['active'] == true) {
            final serverNonce = data['nonce'];
            if (serverNonce == null ||
                (serverNonce is String && serverNonce == nonce)) {
              // Do not resurrect a credential after an explicit user stop was
              // recorded while SSV confirmation was in flight.
              if (await CryptoService.isSessionStopPending()) return false;
              await setSessionNonce(nonce);
              await CryptoService.clearSessionStopPending();
              return true;
            }
            return false;
          }
        } else if (response.statusCode == 401) {
          // The server has definitively rejected this candidate.
          return false;
        }
      } catch (_) {}

      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 750));
      }
    }

    return false;
  }

  /// Revoke the currently-authorized server session. Persist the revocation
  /// intent before the first network write and clear it only on a definitive
  /// success/unauthorized result. Ambiguous failure remains fail-closed.
  static Future<SessionStopResult> stopSession({bool markPending = true}) async {
    final existing = _stopInFlight;
    if (existing != null) return existing;

    final operation = _stopSessionInner(markPending: markPending);
    _stopInFlight = operation;
    try {
      return await operation;
    } finally {
      if (identical(_stopInFlight, operation)) {
        _stopInFlight = null;
      }
    }
  }

  static Future<SessionStopResult> _stopSessionInner({
    required bool markPending,
  }) async {
    final nonce = await getSessionNonce();
    if (nonce == null) {
      await CryptoService.clearSessionStopPending();
      return SessionStopResult.alreadyInactive;
    }

    if (markPending) {
      await CryptoService.setSessionStopPending();
    }

    final deviceId = await CryptoService.getDeviceId();
    final body = jsonEncode(<String, String>{'device_id': deviceId});

    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await directPost(
          _publicUrl('/session/stop'),
          body: body,
          timeout: const Duration(seconds: 4),
          headers: <String, String>{_sessionNonceHeader: nonce},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['ok'] == true) {
            await clearSessionNonce();
            return SessionStopResult.stopped;
          }
        } else if (response.statusCode == 401) {
          await clearSessionNonce();
          return SessionStopResult.alreadyInactive;
        }
      } catch (_) {}

      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    return SessionStopResult.retryNeeded;
  }

  static Future<bool> retryPendingSessionStop() async {
    if (!await CryptoService.isSessionStopPending()) return true;
    final result = await stopSession(markPending: false);
    return result != SessionStopResult.retryNeeded;
  }

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
  }) async {
    // Capture the generation before the first await. A disconnect during
    // secure-storage access must invalidate the whole operation.
    final callId = ++_currentCallId;
    final deviceId = await CryptoService.getDeviceId();
    _throwIfCancelled(callId);

    var nonce = await getSessionNonce();
    _throwIfCancelled(callId);

    // Legacy unsigned callback is strictly a debug compatibility path. A
    // candidate is persisted only after the server confirms it as active.
    if (nonce == null && !skipAdBypass && kDebugMode) {
      final candidate = newNonce();
      try {
        final customData = jsonEncode(<String, String>{
          'device_id': deviceId,
          'ad_type': 'main',
          'nonce': candidate,
        });
        final callback = _publicUrl(
          '/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}',
        );
        final response = await directGet(
          callback,
          timeout: const Duration(seconds: 8),
        );
        _throwIfCancelled(callId);
        if (response.statusCode == 200 &&
            await confirmAndSetSessionNonce(candidate)) {
          _throwIfCancelled(callId);
          nonce = candidate;
        }
      } catch (e) {
        if (_isCancelledError(e)) rethrow;
      }
    }

    if (nonce == null) {
      throw Exception('Session authorization unavailable.');
    }

    const maxAttempts = 5;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      _throwIfCancelled(callId);
      onAttempt?.call(attempt, maxAttempts);

      try {
        final session = await _fetchActiveSession(deviceId, nonce);
        _throwIfCancelled(callId);
        if (session != null) return session.toVlessUrl();
      } catch (e) {
        if (_isCancelledError(e)) rethrow;
        debugPrint('[Hivemind] session attempt $attempt failed');
      }

      if (attempt < maxAttempts) {
        await Future.delayed(_pollBackoff[attempt - 1]);
        _throwIfCancelled(callId);
      }
    }

    throw Exception('Session not activated. Server callback may have timed out.');
  }

  static Future<bool> checkHealth() async {
    try {
      final response = await directGet(
        _publicUrl('/health'),
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<_HivemindSessionConfig?> _fetchActiveSession(
    String deviceId,
    String nonce,
  ) async {
    final response = await directGet(
      _sessionStatusUrl(deviceId),
      headers: <String, String>{_sessionNonceHeader: nonce},
    );

    if (response.statusCode == 401) {
      await clearSessionNonce();
      throw Exception('Session authorization unavailable.');
    }
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    final serverNonce = decoded['nonce'];
    if (serverNonce != null &&
        (serverNonce is! String || serverNonce != nonce)) {
      return null;
    }

    if (decoded['active'] != true || decoded['vless_uuid'] == null) {
      return null;
    }

    return _HivemindSessionConfig.fromJson(decoded);
  }

  static void _throwIfCancelled(int callId) {
    if (_currentCallId != callId) throw Exception('Cancelled');
  }

  static bool _isCancelledError(Object error) =>
      error.toString().contains('Cancelled');

  static Uri _configuredApiBase() {
    final base = Uri.tryParse(AppConfig.hivemindApiPublic.trim());
    if (base == null ||
        base.scheme != 'https' ||
        !base.hasAuthority ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty) {
      throw StateError('hivemindApiPublic must be a canonical HTTPS base URL.');
    }
    return base;
  }

  static void _validateApiUri(Uri uri) {
    final base = _configuredApiBase();
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.origin != base.origin) {
      throw ArgumentError.value(
        uri,
        'uri',
        'API requests must remain on the configured HTTPS origin',
      );
    }
  }

  static Uri _publicUrl(String path) {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError.value(path, 'path', 'expected an absolute API path');
    }

    final base = _configuredApiBase();
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    final uri = Uri.parse('$baseText$path');
    _validateApiUri(uri);
    return uri;
  }

  static Uri _sessionStatusUrl(String deviceId) {
    return _publicUrl('/session/status').replace(
      queryParameters: <String, String>{'device_id': deviceId},
    );
  }
}

class _HivemindSessionConfig {
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final RegExp _shortIdPattern =
      RegExp(r'^[0-9a-f]{0,16}$', caseSensitive: false);

  final String uuid;
  final String host;
  final int port;
  final String publicKey;
  final String shortId;
  final String sni;
  final String fingerprint;
  final String path;

  const _HivemindSessionConfig({
    required this.uuid,
    required this.host,
    required this.port,
    required this.publicKey,
    required this.shortId,
    required this.sni,
    required this.fingerprint,
    required this.path,
  });

  factory _HivemindSessionConfig.fromJson(Map<String, dynamic> json) {
    final uuid = _requiredString(json, 'vless_uuid', maxLength: 64);
    if (!_uuidPattern.hasMatch(uuid)) {
      throw const FormatException('Invalid VLESS UUID');
    }

    // The control plane may rotate credentials and Reality parameters, but it
    // cannot choose the tunnel destination. Keep host/port as compiled pins.
    final pinnedHost = _validatedPublicIp(AppConfig.serverIp, 'serverIp');
    final advertisedHost = json['vless_ip'];
    if (advertisedHost != null) {
      if (advertisedHost is! String || advertisedHost.trim() != pinnedHost) {
        throw const FormatException(
          'Session VLESS host does not match compiled server pin',
        );
      }
    }
    final host = pinnedHost;

    final advertisedPort = json['vless_port'];
    if (advertisedPort != null &&
        (advertisedPort is! num || advertisedPort.toInt() != 443)) {
      throw const FormatException(
        'Session VLESS port does not match compiled pin',
      );
    }
    const port = 443;

    final sni = _validatedHost(
      _requiredString(json, 'reality_sni', maxLength: 253),
      'reality_sni',
    );
    final publicKey = _requiredString(json, 'reality_pbk', maxLength: 128);
    final shortId = _stringOr(json['reality_sid'], '').trim();
    if (!_shortIdPattern.hasMatch(shortId)) {
      throw const FormatException('Invalid Reality short ID');
    }

    final fingerprint = _boundedString(
      json['reality_fp'],
      AppConfig.realityFp,
      32,
      'reality_fp',
    );
    final path = _boundedString(
      json['xhttp_path'],
      AppConfig.vlessPath,
      2048,
      'xhttp_path',
    );
    if (!path.startsWith('/')) {
      throw const FormatException('Invalid XHTTP path');
    }

    return _HivemindSessionConfig(
      uuid: uuid,
      host: host,
      port: port,
      publicKey: publicKey,
      shortId: shortId,
      sni: sni,
      fingerprint: fingerprint,
      path: path,
    );
  }

  String toVlessUrl() {
    return Uri(
      scheme: 'vless',
      userInfo: uuid,
      host: host,
      port: port,
      queryParameters: <String, String>{
        'security': AppConfig.vlessSecurity,
        'type': AppConfig.vlessType,
        'path': path,
        'pbk': publicKey,
        'sni': sni,
        'sid': shortId,
        'fp': fingerprint,
      },
      fragment: 'Revolt VPN',
    ).toString();
  }

  static String _requiredString(
    Map<String, dynamic> json,
    String key, {
    int maxLength = 4096,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Missing required session field: $key');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maxLength) {
      throw FormatException('Invalid session field: $key');
    }
    return trimmed;
  }

  static String _stringOr(Object? value, String fallback) {
    return value is String && value.trim().isNotEmpty ? value.trim() : fallback;
  }

  static String _boundedString(
    Object? value,
    String fallback,
    int maxLength,
    String field,
  ) {
    final result = _stringOr(value, fallback);
    if (result.isEmpty || result.length > maxLength) {
      throw FormatException('Invalid session field: $field');
    }
    return result;
  }

  static String _validatedHost(String input, String field) {
    final value = input.trim();
    if (value.isEmpty ||
        value.length > 253 ||
        value.contains(RegExp(r'[\s/@?#]'))) {
      throw FormatException('Invalid session host: $field');
    }
    try {
      final probe = Uri(scheme: 'https', host: value);
      if (probe.host.isEmpty) {
        throw FormatException('Invalid session host: $field');
      }
    } on FormatException {
      throw FormatException('Invalid session host: $field');
    }
    return value;
  }

  static String _validatedPublicIp(String input, String field) {
    final value = input.trim().toLowerCase();
    if (_isPublicIpv4(value) || _isPublicIpv6(value)) return value;
    throw FormatException('Invalid public IP pin: $field');
  }

  static bool _isPublicIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) {
        return false;
      }
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0 || parsed > 255) return false;
      octets.add(parsed);
    }

    final a = octets[0];
    final b = octets[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0 && octets[2] == 2) return false;
    if (a == 198 && b == 51 && octets[2] == 100) return false;
    if (a == 203 && b == 0 && octets[2] == 113) return false;
    return true;
  }

  static bool _isPublicIpv6(String value) {
    if (!value.contains(':') || value.contains('.')) return false;
    try {
      final parsed = Uri.parse('https://[$value]/');
      if (parsed.host.isEmpty || !parsed.host.contains(':')) return false;
    } on FormatException {
      return false;
    }

    if (value == '::' || value == '::1') return false;
    if (value.startsWith('fc') || value.startsWith('fd')) return false;
    if (value.startsWith('fe8') ||
        value.startsWith('fe9') ||
        value.startsWith('fea') ||
        value.startsWith('feb')) {
      return false;
    }
    if (value.startsWith('ff')) return false;
    if (value.startsWith('2001:db8:') || value == '2001:db8::') return false;
    return true;
  }
}
