import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/crypto_service.dart';

class HivemindService {
  /// Polls the Hivemind server until the session is ready or timeout occurs.
  /// Returns the WireGuard config string.
  static Future<String> fetchConfigWithPolling() async {
    final deviceId = await CryptoService.getDeviceId();
    final keys = await CryptoService.getOrCreateKeys();
    final privKey = keys['privateKey']!;
    
    final url = Uri.parse('${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');

    // ── TEMPORARY AD BYPASS HACK FOR TESTING ──
    // Since you disabled the crypto signature check on the Python server,
    // we can just send a fake "Ad Watched" ping from the app directly.
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
    // ──────────────────────────────────────────

    int attempts = 0;
    while (attempts < 15) {
      try {
        final response = await http.get(url).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          
          // Debugging log to see exactly what the server returned
          print('[HivemindService] Polling response: ${response.body}');
          
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
          print('[HivemindService] Non-200 status: ${response.statusCode}');
        }
      } catch (e) {
        print('[HivemindService] Polling exception: $e');
        // Ignore network errors and keep polling
      }
      
      attempts++;
      await Future.delayed(const Duration(seconds: 2));
    }

    throw Exception("Session not activated. S2S callback failed or timed out.");
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
