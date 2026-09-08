import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

class HivemindService {
  static String? _sessionNonce;
  static int _currentCallId = 0;
  static final Random _secureRandom = Random.secure();

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

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
  }) async {
    final deviceId = await CryptoService.getDeviceId();
    final callId = ++_currentCallId;

    // Real AdMob main SSV creates and persists the nonce before this method is called. Preserve
    // that exact possession token. Only debug compatibility mode may mint one here and emit the
    // unsigned local callback.
    var nonce = await getSessionNonce();
    if (nonce == null && !skipAdBypass && kDebugMode) {
      nonce = newNonce();
      await setSessionNonce(nonce);
      try {
        final customData = jsonEncode({'device_id': deviceId, 'nonce': nonce});
        final fakeUrl = _publicUrl(
            '/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}');
        await directGet(fakeUrl, timeout: const Duration(seconds: 8));
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
