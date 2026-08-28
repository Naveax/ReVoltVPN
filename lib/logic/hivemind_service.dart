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
  static final Random _secureRandom = Random.secure();

  static const _ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  static Future<http.Response> directGet(
    Uri uri, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return http.get(uri, headers: {'User-Agent': _ua}).timeout(timeout);
  }

  /// Creates a cryptographically strong nonce that is carried from the ad's
  /// SSV custom_data all the way through server verification and config fetch.
  static String createSessionNonce() {
    final bytes = List<int>.generate(18, (_) => _secureRandom.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static void cancel() {
    _currentCallId++;
    clearExpectedNonce();
  }

  static void setExpectedNonce(String nonce) {
    if (nonce.isEmpty) {
      throw ArgumentError.value(nonce, 'nonce', 'Nonce must not be empty');
    }
    _expectedNonce = nonce;
  }

  static void clearExpectedNonce([String? expected]) {
    if (expected == null || _expectedNonce == expected) {
      _expectedNonce = null;
    }
  }

  /// Waits for Hivemind to report an active session tied to the exact nonce
  /// sent through AdMob SSV. A local rewarded-ad callback is not sufficient.
  static Future<bool> waitForSessionActivation({
    required String expectedNonce,
    Duration timeout = const Duration(seconds: 25),
    Duration pollInterval = const Duration(seconds: 1),
  }) async {
    final deviceId = await CryptoService.getDeviceId();
    final url = _sessionStatusUrl(deviceId);
    final deadline = DateTime.now().add(timeout);
    final callId = _currentCallId;

    while (DateTime.now().isBefore(deadline)) {
      if (_currentCallId != callId) return false;

      try {
        final response = await directGet(
          url,
          timeout: const Duration(seconds: 5),
        );

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) {
            final serverNonce = decoded['nonce']?.toString();
            final active = decoded['active'] == true;

            if (active && serverNonce == expectedNonce) {
              return true;
            }
          }
        }
      } catch (e) {
        debugPrint('[HivemindService] SSV verification poll failed: $e');
      }

      await Future.delayed(pollInterval);
    }

    return false;
  }

  /// Fetches tunnel configuration only for a session that has already been
  /// verified by the server using the SSV nonce set by [AdManager].
  ///
  /// There is deliberately no production test-callback/bypass path here.
  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
  }) async {
    final expectedNonce = _expectedNonce;
    if (expectedNonce == null || expectedNonce.isEmpty) {
      throw Exception('Verified ad session required before config fetch.');
    }

    final deviceId = await CryptoService.getDeviceId();
    final callId = ++_currentCallId;
    final url = _sessionStatusUrl(deviceId);

    const maxAttempts = 5;
    for (int i = 1; i <= maxAttempts; i++) {
      if (_currentCallId != callId) throw Exception('Cancelled');

      onAttempt?.call(i, maxAttempts);
      try {
        final response = await directGet(url);
        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('Invalid session response');
          }

          final serverNonce = decoded['nonce']?.toString();
          if (serverNonce != expectedNonce) {
            debugPrint('[HivemindService] Session nonce mismatch; refusing config.');
          } else if (decoded['active'] == true && decoded['vless_uuid'] != null) {
            final vlessUuid = decoded['vless_uuid']?.toString() ?? '';
            final vlessIp = decoded['vless_ip']?.toString() ?? AppConfig.serverIp;
            final vlessPort = decoded['vless_port'] ?? 443;
            final pbk = decoded['reality_pbk']?.toString() ?? '';
            final sid = decoded['reality_sid']?.toString() ?? '';
            final sni = decoded['reality_sni']?.toString() ?? '';
            final fp = decoded['reality_fp']?.toString() ?? AppConfig.realityFp;
            final xhttpPath =
                decoded['xhttp_path']?.toString() ?? AppConfig.vlessPath;

            if (vlessUuid.isEmpty || pbk.isEmpty || sni.isEmpty) {
              throw const FormatException(
                'Server returned incomplete VLESS/REALITY configuration',
              );
            }

            final vlessUrl = 'vless://$vlessUuid@$vlessIp:$vlessPort'
                '?security=${AppConfig.vlessSecurity}'
                '&type=${AppConfig.vlessType}'
                '&path=$xhttpPath'
                '&pbk=${Uri.encodeComponent(pbk)}'
                '&sni=${Uri.encodeComponent(sni)}'
                '&sid=${Uri.encodeComponent(sid)}'
                '&fp=${Uri.encodeComponent(fp)}'
                '#Revolt VPN';

            clearExpectedNonce(expectedNonce);
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

    clearExpectedNonce(expectedNonce);
    throw Exception('Session not activated or SSV nonce verification failed.');
  }

  static Future<bool> checkHealth() async {
    try {
      final url = Uri.parse('${AppConfig.hivemindApiPublic}/health');
      final response = await directGet(
        url,
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Uri _sessionStatusUrl(String deviceId) {
    final base = Uri.parse('${AppConfig.hivemindApiPublic}/session/status');
    return base.replace(
      queryParameters: {
        ...base.queryParameters,
        'device_id': deviceId,
      },
    );
  }
}
