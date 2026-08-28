import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

class HivemindService {
  static String? _expectedNonce;
  static int _currentCallId = 0;

  static const _ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return http.get(uri, headers: {'User-Agent': _ua}).timeout(timeout);
  }

  static void cancel() {
    _currentCallId++;
  }

  static void setExpectedNonce(String nonce) {
    _expectedNonce = nonce;
  }

  static void clearExpectedNonce() {
    _expectedNonce = null;
  }

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
  }) async {
    final deviceId = await CryptoService.getDeviceId();
    final callId = ++_currentCallId;

    // Preserve the nonce placed in AdMob SSV custom_data. Generating a new
    // nonce here would make a legitimate SSV response impossible to match.
    final expectedNonce = _expectedNonce;
    final url = _publicUrl('/session/status?device_id=$deviceId');

    const maxAttempts = 8;
    for (int i = 1; i <= maxAttempts; i++) {
      if (_currentCallId != callId) throw Exception('Cancelled');

      onAttempt?.call(i, maxAttempts);
      try {
        final response = await directGet(url);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is! Map<String, dynamic>) {
            throw const FormatException('Invalid session response');
          }

          final serverNonce = data['nonce'] as String?;
          if (expectedNonce != null && serverNonce != expectedNonce) {
            debugPrint('[HivemindService] SSV nonce mismatch; retrying.');
          } else if (data['active'] == true && data['vless_uuid'] != null) {
            final vlessUuid = data['vless_uuid'];
            final vlessIp = data['vless_ip'] ?? AppConfig.serverIp;
            final vlessPort = data['vless_port'] ?? 443;
            final pbk = data['reality_pbk'] ?? '';
            final sid = data['reality_sid'] ?? '';
            final sni = data['reality_sni'];
            if (sni == null) {
              throw Exception('Server did not provide reality_sni');
            }
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

            if (_expectedNonce == expectedNonce) {
              _expectedNonce = null;
            }
            return vlessUrl;
          }
        }
      } catch (e) {
        if (e.toString().contains('Cancelled')) rethrow;
        debugPrint('[HivemindService] Attempt $i failed: $e');
      }

      if (i < maxAttempts) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    throw Exception('Session not activated or SSV verification timed out.');
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

  static Uri _publicUrl(String path) =>
      Uri.parse('${AppConfig.hivemindApiPublic}$path');
}
