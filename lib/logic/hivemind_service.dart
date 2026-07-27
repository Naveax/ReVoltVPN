import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

class HivemindService {
  static String? _expectedNonce;
  static int _currentCallId = 0;

  /// Call this from disconnect to abort any in-progress polling.
  static void cancel() {
    _currentCallId++; // bump — any running loop sees a stale ID and exits
  }

  static void setExpectedNonce(String nonce) {
    _expectedNonce = nonce;
  }

  /// Tries to fetch the VLESS config from the server.
  /// Only polls a few times — by the time the ad finishes, the SSV callback
  /// has usually already fired.
  static Future<String> fetchConfigWithPolling({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
    bool quickReconnect = false,
  }) async {
    final deviceId = await CryptoService.getDeviceId();

    final callId = ++_currentCallId;
    final nonce = '${Random().nextInt(0x7FFFFFFF)}-${DateTime.now().millisecondsSinceEpoch}';
    _expectedNonce = nonce;
    debugPrint('[HivemindService] Call #$callId — nonce: $nonce');

    final url = Uri.parse('${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');

    // ── AD BYPASS (debug only) ────────────────────────────────────────
    if (kDebugMode && !skipAdBypass) {
      try {
        final customData = jsonEncode({'device_id': deviceId, 'nonce': nonce});
        final fakeUrl = Uri.parse(
            '${AppConfig.hivemindApiBase}/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}');
        await http.get(fakeUrl).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    final maxAttempts = quickReconnect ? 1 : 5;
    for (int i = 1; i <= maxAttempts; i++) {
      if (_currentCallId != callId) throw Exception('Cancelled');

      onAttempt?.call(i, maxAttempts);
      try {
        final response = await http.get(url).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);

          final serverNonce = data['nonce'] as String?;
          if (_expectedNonce != null && serverNonce != null && serverNonce != _expectedNonce) {
            debugPrint('[HivemindService] Nonce mismatch — retrying…');
          } else if (data['active'] == true && data['vless_uuid'] != null) {
            final vlessUuid = data['vless_uuid'];
            final vlessPath = data['vless_path'] ?? AppConfig.vlessPath;
            final vlessUrl = 'vless://$vlessUuid@${AppConfig.serverDomain}:${AppConfig.serverPort}'
                '?path=${Uri.encodeComponent(vlessPath)}'
                '&security=${AppConfig.vlessSecurity}'
                '&type=${AppConfig.vlessType}'
                '#ReVoltVPN';
            _expectedNonce = null;
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

  static Future<bool> verifySession() async {
    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse('${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['active'] == true;
      }
    } catch (_) {}
    return false;
  }

  static Future<void> disconnectAndCleanup() async {
    final deviceId = await CryptoService.getDeviceId();
    final url = Uri.parse('${AppConfig.hivemindApiBase}/session/stop');
    try {
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'device_id': deviceId}),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}
