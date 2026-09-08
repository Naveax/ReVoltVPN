import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/control_plane_policy.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/session_auth.dart';

class HivemindService {
  static String? _pendingNonce;
  static String? _activeSessionNonce;
  static Future<String?>? _activeSessionNonceLoad;
  static int _activeSessionAuthEpoch = 0;
  static int _currentCallId = 0;

  static const FlutterSecureStorage _sessionStorage = FlutterSecureStorage();
  static const String _activeSessionNonceKey = 'revolt_active_session_nonce_v1';

  static const _ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
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
  }) {
    return controlGet(uri, timeout: timeout);
  }

  static Future<http.Response> controlGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
    Map<String, String> headers = const <String, String>{},
  }) {
    final validatedUri = ControlPlanePolicy.validate(
      requested: uri,
      configuredBase: AppConfig.hivemindApiPublic,
    );
    final request = http.Request('GET', validatedUri)
      ..headers.addAll(headers)
      ..headers['User-Agent'] = _ua
      ..followRedirects = false;
    return _sendControlRequest(request, timeout);
  }

  static Future<http.Response> _controlPostJson(
    Uri uri,
    Map<String, Object?> body, {
    required Map<String, String> headers,
    Duration timeout = const Duration(seconds: 3),
  }) {
    final validatedUri = ControlPlanePolicy.validate(
      requested: uri,
      configuredBase: AppConfig.hivemindApiPublic,
    );
    final request = http.Request('POST', validatedUri)
      ..headers.addAll(headers)
      ..headers['User-Agent'] = _ua
      ..headers['Content-Type'] = 'application/json'
      ..followRedirects = false
      ..body = jsonEncode(body);
    return _sendControlRequest(request, timeout);
  }

  static Future<http.Response> _sendControlRequest(
    http.Request request,
    Duration timeout,
  ) async {
    final client = http.Client();

    Future<http.Response> read() async {
      final streamed = await client.send(request);
      final declaredLength = streamed.contentLength;
      if (declaredLength != null && declaredLength > _maxControlResponseBytes) {
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

  /// Cancel in-flight activation work without destroying authorization for an
  /// already-running server session. An unconfirmed native STOP still needs
  /// authenticated quota/status sync to fail closed safely.
  static void cancel() {
    _currentCallId++;
    _pendingNonce = null;
  }

  /// Compatibility hook used by the existing rewarded-ad path. The active
  /// session credential is promoted only after an authenticated status response.
  static void setExpectedNonce(String nonce) {
    _pendingNonce = nonce;
  }

  static Future<String?> _loadActiveSessionNonce() async {
    final cached = _activeSessionNonce;
    if (cached != null && SessionAuth.isValidNonce(cached)) return cached;

    final inFlight = _activeSessionNonceLoad;
    if (inFlight != null) return inFlight;

    final epoch = _activeSessionAuthEpoch;
    final operation = _readActiveSessionNonce(epoch);
    _activeSessionNonceLoad = operation;
    try {
      return await operation;
    } finally {
      if (identical(_activeSessionNonceLoad, operation)) {
        _activeSessionNonceLoad = null;
      }
    }
  }

  static Future<String?> _readActiveSessionNonce(int epoch) async {
    final stored = await _sessionStorage.read(key: _activeSessionNonceKey);
    if (epoch != _activeSessionAuthEpoch) return null;
    if (stored == null) return null;
    if (!SessionAuth.isValidNonce(stored)) {
      await _sessionStorage.delete(key: _activeSessionNonceKey);
      return null;
    }
    if (epoch != _activeSessionAuthEpoch) return null;
    _activeSessionNonce = stored;
    return stored;
  }

  static Future<void> _storeActiveSessionNonce(String nonce) async {
    if (!SessionAuth.isValidNonce(nonce)) {
      throw const FormatException('Invalid active session authorization nonce.');
    }
    final epoch = ++_activeSessionAuthEpoch;
    await _sessionStorage.write(key: _activeSessionNonceKey, value: nonce);
    if (epoch != _activeSessionAuthEpoch) return;
    _activeSessionNonce = nonce;
  }

  static Future<void> clearActiveSessionAuthorization() async {
    _activeSessionAuthEpoch++;
    _activeSessionNonce = null;
    _activeSessionNonceLoad = null;
    await _sessionStorage.delete(key: _activeSessionNonceKey);
  }

  static Future<http.Response> sessionStatus(
    String deviceId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final nonce = await _loadActiveSessionNonce();
    if (nonce == null) {
      throw StateError('Active session authorization is unavailable.');
    }
    return _sessionStatusWithNonce(deviceId, nonce, timeout: timeout);
  }

  static Future<http.Response> _sessionStatusWithNonce(
    String deviceId,
    String nonce, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final statusUri = _publicUrl('/session/status').replace(
      queryParameters: {'device_id': deviceId},
    );
    return controlGet(
      statusUri,
      timeout: timeout,
      headers: SessionAuth.headers(nonce),
    );
  }

  /// Revoke the currently-owned server credential after local/native shutdown
  /// has already been proven. Network/control-plane failure never turns a local
  /// disconnect back into a connected state; the nonce is retained for a later
  /// retry or replacement session unless the server confirms revocation.
  static Future<bool> revokeActiveSession(
    String deviceId, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final nonce = await _loadActiveSessionNonce();
    if (nonce == null) return false;

    try {
      final response = await _controlPostJson(
        _publicUrl('/session/stop'),
        <String, Object?>{'device_id': deviceId},
        headers: SessionAuth.headers(nonce),
        timeout: timeout,
      );
      if (response.statusCode != 200) return false;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) return false;
      await clearActiveSessionAuthorization();
      return true;
    } catch (error) {
      debugPrint('[Hivemind] session revoke failed: $error');
      return false;
    }
  }

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
  }) async {
    // Capture the generation before the first await. Otherwise a disconnect
    // that lands while secure storage is resolving the device ID can be lost
    // and the cancelled call can resume network work with a fresh generation.
    final callId = ++_currentCallId;
    final deviceId = await CryptoService.getDeviceId();
    _throwIfCancelled(callId);

    final nonce = SessionAuth.newNonce();
    _pendingNonce = nonce;

    if (!skipAdBypass) {
      await _runConfiguredBypass(deviceId, nonce);
      _throwIfCancelled(callId);
    }

    const maxAttempts = 5;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      _throwIfCancelled(callId);
      onAttempt?.call(attempt, maxAttempts);

      try {
        final session = await _fetchActiveSession(deviceId, nonce);
        _throwIfCancelled(callId);
        if (session != null) {
          // Persist the authorization before the tunnel starts. If the Flutter
          // process later dies, the adopted native runtime must still be able
          // to authenticate quota/expiry status checks.
          await _storeActiveSessionNonce(nonce);
          _throwIfCancelled(callId);
          _pendingNonce = null;
          return session.toVlessUrl();
        }
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
      // AppConfig.hivemindApiPublic is the /api base; the Rust daemon exposes
      // its public health contract at /api/v2/health.
      final response = await controlGet(
        _publicUrl('/v2/health'),
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _runConfiguredBypass(String deviceId, String nonce) async {
    try {
      final customData = jsonEncode({'device_id': deviceId, 'nonce': nonce});
      final callback = _publicUrl(
        '/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}',
      );
      await directGet(callback, timeout: const Duration(seconds: 8));
    } catch (_) {
      // Validation bypass behavior is intentionally best-effort in this build.
    }
  }

  static Future<_HivemindSessionConfig?> _fetchActiveSession(
    String deviceId,
    String nonce,
  ) async {
    final response = await _sessionStatusWithNonce(deviceId, nonce);
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    // The Rust API authenticates the request with the session nonce header and
    // intentionally does not reflect that bearer credential in the response.
    if (_pendingNonce != nonce) return null;
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

  static Uri _publicUrl(String path) =>
      Uri.parse('${AppConfig.hivemindApiPublic}$path');
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

    // The API may rotate credentials and Reality parameters, but it must never
    // choose the tunnel destination. Keep that trust anchor compiled into the
    // app so an API/domain compromise can cause denial of service, not redirect
    // VPN traffic to an attacker-controlled server.
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
      throw const FormatException('Session VLESS port does not match compiled pin');
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

    final fingerprint =
        _boundedString(json['reality_fp'], AppConfig.realityFp, 32, 'reality_fp');
    final path =
        _boundedString(json['xhttp_path'], AppConfig.vlessPath, 2048, 'xhttp_path');
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
      if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
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
    if (value.startsWith('fe8') || value.startsWith('fe9') || value.startsWith('fea') || value.startsWith('feb')) return false;
    if (value.startsWith('ff')) return false;
    if (value.startsWith('2001:db8:') || value == '2001:db8::') return false;
    return true;
  }
}
