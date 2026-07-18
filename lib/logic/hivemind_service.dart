import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/crypto_service.dart';

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

    // ── Generate a connect nonce ──────────────────────────────────────
    // Every fresh connect cycle gets a new random token.  The server
    // stores it in the session and echoes it back in /session/status.
    // If the poll returns a session whose nonce differs (e.g. a stale
    // leftover from a failed disconnectAndCleanup), we skip it and keep
    // polling until the right session appears or the timeout fires.
    final nonce = '${Random().nextInt(0x7FFFFFFF)}-${DateTime.now().millisecondsSinceEpoch}';
    _expectedNonce = nonce;
    debugPrint('[HivemindService] Connect nonce: $nonce');
    
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
          // Reject any session whose nonce doesn't match what we sent.
          // If the server is old and doesn't return a nonce we still
          // accept it (backwards-compat), but a mismatch is a hard skip.
          final serverNonce = data['nonce'] as String?;
          if (_expectedNonce != null && serverNonce != null && serverNonce != _expectedNonce) {
            debugPrint('[HivemindService] Nonce mismatch (expected $_expectedNonce, got $serverNonce) — stale session, retrying…');
            // Fall through to retry — do NOT accept this session.
          } else if (data['active'] == true && data['client_ip'] != null && data['server_pubkey'] != null) {
            final clientIp = data['client_ip'];
            final clientIpv6 = data['client_ipv6'] ?? '';
            final serverPubkey = data['server_pubkey'];

            // Build dual-stack Address: IPv4/16 + optional IPv6/80
            final addresses = clientIpv6.isNotEmpty
                ? '$clientIp/16, $clientIpv6/80'
                : '$clientIp/16';

            // Construct the WireGuard config locally
            final configText = '''
[Interface]
PrivateKey = $privKey
Address = $addresses
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
            _expectedNonce = null; // consumed successfully
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
