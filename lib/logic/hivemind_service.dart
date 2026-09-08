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

  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? headers,
  }) {
    return http
        .get(uri, headers: {'User-Agent': _ua, ...?headers})
        .timeout(timeout);
  }

  static Future<http.Response> directPost(
    Uri uri, {
    required String body,
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? headers,
  }) {
    return http
        .post(
          uri,
          headers: {
            'User-Agent': _ua,
            'Content-Type': 'application/json',
            ...?headers,
          },
          body: body,
        )
        .timeout(timeout);
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
      headers: {_sessionNonceHeader: nonce},
    );
  }

  /// Probe the currently persisted possession token without minting a replacement.
  /// A definitive inactive response invalidates the local token. Network/server ambiguity
  /// is fail-closed and leaves the token untouched so callers cannot accidentally replace a
  /// still-live server generation with a fresh AdMob nonce.
  static Future<SessionProbeResult> probeCurrentSession() async {
    final nonce = await getSessionNonce();
    if (nonce == null) return SessionProbeResult.inactive;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final response = await directGet(
        _publicUrl('/session/status?device_id=$deviceId'),
        timeout: const Duration(seconds: 3),
        headers: {_sessionNonceHeader: nonce},
      );
      if (response.statusCode != 200) {
        return SessionProbeResult.unavailable;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return SessionProbeResult.unavailable;
      }
      if (data['active'] == true) {
        final serverNonce = data['nonce'] as String?;
        if (serverNonce != null && serverNonce != nonce) {
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

  /// Commit a candidate main-session nonce only after the server projects that exact nonce as
  /// active. This closes the client-side window where a locally-earned ad could overwrite the
  /// previous possession token before Google SSV was accepted by the server.
  static Future<bool> confirmAndSetSessionNonce(String nonce) async {
    final deviceId = await CryptoService.getDeviceId();
    final url = _publicUrl('/session/status?device_id=$deviceId');

    const maxAttempts = 8;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await directGet(
          url,
          timeout: const Duration(seconds: 2),
          headers: {_sessionNonceHeader: nonce},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['active'] == true) {
            final serverNonce = data['nonce'] as String?;
            if (serverNonce == null || serverNonce == nonce) {
              await setSessionNonce(nonce);
              await CryptoService.clearSessionStopPending();
              return true;
            }
            return false;
          }
        }
      } catch (_) {}

      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 750));
      }
    }

    return false;
  }

  /// Revoke the currently-authorized server session. The revocation intent is persisted before
  /// the first network write and cleared only after a definitive 200/401 response. Ambiguous
  /// failures keep both the nonce and pending marker so a later process can retry safely.
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

  static Future<SessionStopResult> _stopSessionInner({required bool markPending}) async {
    final nonce = await getSessionNonce();
    if (nonce == null) {
      await CryptoService.clearSessionStopPending();
      return SessionStopResult.alreadyInactive;
    }

    if (markPending) {
      await CryptoService.setSessionStopPending();
    }

    final deviceId = await CryptoService.getDeviceId();
    final url = _publicUrl('/session/stop');
    final body = jsonEncode({'device_id': deviceId});

    const maxAttempts = 3;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await directPost(
          url,
          body: body,
          timeout: const Duration(seconds: 4),
          headers: {_sessionNonceHeader: nonce},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['ok'] == true) {
            await clearSessionNonce();
            return SessionStopResult.stopped;
          }
        } else if (response.statusCode == 401) {
          // The possession token is no longer authorized, so there is no live credential left
          // for this client to revoke.
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
    final deviceId = await CryptoService.getDeviceId();
    final callId = ++_currentCallId;

    // Preserve the exact possession token established by a successful main AdMob callback.
    // Only debug compatibility mode may mint a candidate here, and even then it is not persisted
    // until the server confirms that exact nonce as active.
    var nonce = await getSessionNonce();
    if (nonce == null && !skipAdBypass && kDebugMode) {
      final candidate = newNonce();
      try {
        final customData = jsonEncode({'device_id': deviceId, 'nonce': candidate});
        final fakeUrl = _publicUrl(
            '/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}');
        final response =
            await directGet(fakeUrl, timeout: const Duration(seconds: 8));
        if (response.statusCode == 200 &&
            await confirmAndSetSessionNonce(candidate)) {
          nonce = candidate;
        }
      } catch (_) {}
    }
    if (nonce == null) {
      throw Exception('Session authorization unavailable.');
    }

    final url = _publicUrl('/session/status?device_id=$deviceId');

    const maxAttempts = 5;
    for (int i = 1; i <= maxAttempts; i++) {
      if (_currentCallId != callId) throw Exception('Cancelled');

      onAttempt?.call(i, maxAttempts);
      try {
        final response = await directGet(
          url,
          headers: {_sessionNonceHeader: nonce},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);

          // Older servers echoed the nonce. Accept that compatibility response only when it
          // matches the possession token we sent; newer servers deliberately never echo it.
          final serverNonce = data['nonce'] as String?;
          if (serverNonce != null && serverNonce != nonce) {
            debugPrint('[HivemindService] Session authorization mismatch — retrying…');
          } else if (data['active'] == true && data['vless_uuid'] != null) {
            final vlessUuid = data['vless_uuid'];
            final vlessIp = data['vless_ip'] ?? AppConfig.serverIp;
            final vlessPort = data['vless_port'] ?? 443;
            final pbk = data['reality_pbk'] ?? '';
            final sid = data['reality_sid'] ?? '';
            final sni = data['reality_sni'];
            if (sni == null) throw Exception('Server did not provide reality_sni');
            final fp = data['reality_fp'] ?? AppConfig.realityFp;
            final xhttpPath = data['xhttp_path'] ?? AppConfig.vlessPath;

            final vlessUrl = 'vless://$vlessUuid@$vlessIp:$vlessPort'
                '?security=${AppConfig.vlessSecurity}'
                '&type=${AppConfig.vlessType}'
                '&path=$xhttpPath'
                '&pbk=${Uri.encodeComponent(pbk)}'
                '&sni=${Uri.encodeComponent(sni)}'
                '&sid=${Uri.encodeComponent(sid)}'
                '&fp=${Uri.encodeComponent(fp)}'
                '#Revolt VPN';
            return vlessUrl;
          }
        }
      } catch (e) {
        if (e.toString().contains('Cancelled')) rethrow;
        debugPrint('[HivemindService] Attempt $i failed: $e');
      }

      if (i < maxAttempts) await Future.delayed(const Duration(seconds: 1));
    }

    throw Exception('Session not activated. Server callback may have timed out.');
  }

  static Future<bool> checkHealth() async {
    try {
      final url = Uri.parse('${AppConfig.hivemindApiPublic}/health');
      final response = await directGet(url, timeout: const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── URL builders ──────────────────────────────────────────────────

  static Uri _publicUrl(String path) =>
      Uri.parse('${AppConfig.hivemindApiPublic}$path');
}
