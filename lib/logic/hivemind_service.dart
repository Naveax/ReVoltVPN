import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

class HivemindService {
  /// Nonce generated at the start of a connect cycle.
  /// Sent to the server during session creation and verified in every poll
  /// response so we never accidentally resume a stale session.
  static String? _expectedNonce;

  /// Stores a nonce so that fetchConfigWithPolling can verify it.
  /// Called by AdManager.showAd() before showing a rewarded ad so the
  /// subsequent poll accepts only the session created by *this* ad.
  static void setExpectedNonce(String nonce) {
    _expectedNonce = nonce;
  }

  /// Polls the Hivemind server until the session is ready or timeout occurs.
  /// Returns a VLESS connection URL string.
  ///
  /// [onAttempt] is called after each poll with (current, total) so the UI
  /// can show progress (e.g. "Contacting server (3/15)…").

  static Future<String> fetchConfigWithPolling({
    void Function(int attempt, int total)? onAttempt,
  }) async {
    final deviceId = await CryptoService.getDeviceId();

    // ── Generate a connect nonce ──────────────────────────────────────
    final nonce = '${Random().nextInt(0x7FFFFFFF)}-${DateTime.now().millisecondsSinceEpoch}';
    _expectedNonce = nonce;
    debugPrint('[HivemindService] Connect nonce: $nonce');

    final url = Uri.parse('${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');

    // ── AD BYPASS (debug only) ────────────────────────────────────────
    if (kDebugMode) {
      try {
        final customData = jsonEncode({
          'device_id': deviceId,
          'nonce': nonce,
        });
        final fakeAdmobPingUrl = Uri.parse(
            '${AppConfig.hivemindApiBase}/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}');
        await http.get(fakeAdmobPingUrl).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    // ───────────────────────────────────────────────────────────────────

    int attempts = 0;
    while (attempts < 15) {
      debugPrint('[HivemindService] Polling attempt ${attempts + 1}/15…');
      onAttempt?.call(attempts + 1, 15);
      try {
        final response = await http.get(url).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);

          debugPrint('[HivemindService] Session found, checking nonce…');

          // ── Nonce gate ──────────────────────────────────────────────
          final serverNonce = data['nonce'] as String?;
          if (_expectedNonce != null && serverNonce != null && serverNonce != _expectedNonce) {
            debugPrint('[HivemindService] Nonce mismatch (expected $_expectedNonce, got $serverNonce) — stale session, retrying…');
          } else if (data['active'] == true && data['vless_uuid'] != null) {
            final vlessUuid = data['vless_uuid'];

            // Build VLESS connection URL
            final vlessUrl = 'vless://$vlessUuid@${AppConfig.serverDomain}:${AppConfig.serverPort}'
                '?path=${Uri.encodeComponent(AppConfig.vlessPath)}'
                '&security=${AppConfig.vlessSecurity}'
                '&type=${AppConfig.vlessType}'
                '#ReVoltVPN';

            _expectedNonce = null; // consumed successfully
            return vlessUrl;
          } else if (data['active'] == true && data['client_ip'] != null) {
            // Server is still running AWG — VLESS client cannot use this.
            debugPrint('[HivemindService] Server returned AWG format (client_ip) — server migration needed.');
            throw Exception('Server is running the old AWG protocol. '
                'Please update the server to VLESS.');
          }
        } else {
          debugPrint('[HivemindService] Non-200 status: ${response.statusCode}');
        }
      } catch (e) {
        debugPrint('[HivemindService] Polling exception: $e');
        // Ignore network errors and keep polling
      }

      attempts++;
      await Future.delayed(const Duration(seconds: 2));
    }

    throw Exception("Session not activated. S2S callback failed or timed out.");
  }

  /// Quick one-shot check: does the server have a live session for this device?
  static Future<bool> verifySession() async {
    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse(
          '${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');
      final response = await http.get(url).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['active'] == true;
      }
    } catch (_) {}
    return false;
  }

  /// Disconnects the session (cleans up on server)
  static Future<void> disconnectAndCleanup() async {
    final deviceId = await CryptoService.getDeviceId();
    final url = Uri.parse('${AppConfig.hivemindApiBase}/session/stop');
    try {
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'device_id': deviceId}),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Best effort cleanup
    }
  }

}
