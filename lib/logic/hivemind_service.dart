import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/crypto_service.dart';

class HivemindService {
  /// Polls the Hivemind server until the session is ready or timeout occurs.
  /// Returns the WireGuard config string.
  ///
  /// [onAttempt] is called after each poll with (current, total) so the UI
  /// can show progress (e.g. "Contacting server (3/15)…").
  static Future<String> fetchConfigWithPolling({
    void Function(int attempt, int total)? onAttempt,
  }) async {
    final deviceId = await CryptoService.getDeviceId();
    final keys = await CryptoService.getOrCreateKeys();
    final privKey = keys['privateKey']!;
    
    final url = Uri.parse('${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');

    // ── AD BYPASS (debug only) ────────────────────────────────────────
    // In debug mode, send a fake AdMob callback so the server creates
    // a session without a real ad.  In release mode this code is
    // stripped — sessions are only created by real AdMob SSV callbacks.
    if (kDebugMode) {
      try {
        final customData = jsonEncode({
          'device_id': deviceId,
          'public_key': keys['publicKey']!,
          'ad_type': 'main_ad',
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
          
          debugPrint('[HivemindService] Session active, constructing config…');
          
          if (data['active'] == true && data['client_ip'] != null && data['server_pubkey'] != null) {
            final clientIp = data['client_ip'];
            final serverPubkey = data['server_pubkey'];

            // Construct the WireGuard config locally
            // I CHANGED IPS MAY BREAK STUFF
            final configText = '''
[Interface]
PrivateKey = $privKey
Address = $clientIp/16
DNS = ${AppConfig.dnsServers}
MTU = ${AppConfig.mtu}
Jc = ${AppConfig.awgJc}
Jmin = ${AppConfig.awgJmin}
Jmax = ${AppConfig.awgJmax}
S1 = ${AppConfig.awgS1}
S2 = ${AppConfig.awgS2}
H1 = ${AppConfig.awgH1}
H2 = ${AppConfig.awgH2}
H3 = ${AppConfig.awgH3}
H4 = ${AppConfig.awgH4}

[Peer]
PublicKey = $serverPubkey
AllowedIPs = ${AppConfig.allowedIps}
Endpoint = ${AppConfig.serverEndpoint}
PersistentKeepalive = ${AppConfig.persistentKeepalive}
''';
            return configText;
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
  /// Used by VpnConnection after the tunnel starts to confirm the server-side
  /// session exists before reporting "connected" to the UI.
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
