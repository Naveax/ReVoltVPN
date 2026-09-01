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

  static const _ua = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
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
    return http.get(uri, headers: {'User-Agent': _ua}).timeout(timeout);
  }

  static void cancel() => _currentCallId++;

  static void setExpectedNonce(String nonce) {
    _expectedNonce = nonce;
  }

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
  }) async {
    final deviceId = await CryptoService.getDeviceId();
    final callId = ++_currentCallId;
    final nonce = _newNonce();
    _expectedNonce = nonce;

    if (!skipAdBypass) {
      await _runConfiguredBypass(deviceId, nonce);
    }

    const maxAttempts = 5;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      _throwIfCancelled(callId);
      onAttempt?.call(attempt, maxAttempts);

      try {
        final session = await _fetchActiveSession(deviceId, nonce);
        _throwIfCancelled(callId);
        if (session != null) {
          _expectedNonce = null;
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
      final response = await directGet(
        _publicUrl('/health'),
        timeout: const Duration(seconds: 3),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static String _newNonce() {
    final random = Random.secure();
    final high = random.nextInt(0x7FFFFFFF);
    final low = random.nextInt(0x7FFFFFFF);
    return '$high-$low-${DateTime.now().microsecondsSinceEpoch}';
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
    final statusUri = _publicUrl('/session/status').replace(
      queryParameters: {'device_id': deviceId},
    );
    final response = await directGet(statusUri);
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    final serverNonce = decoded['nonce'];
    if (_expectedNonce != nonce ||
        serverNonce is! String ||
        serverNonce != nonce) {
      return null;
    }

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
    final uuid = _requiredString(json, 'vless_uuid');
    final host = _stringOr(json['vless_ip'], AppConfig.serverIp);
    final port = _portOr(json['vless_port'], 443);
    final sni = _requiredString(json, 'reality_sni');

    return _HivemindSessionConfig(
      uuid: uuid,
      host: host,
      port: port,
      publicKey: _stringOr(json['reality_pbk'], ''),
      shortId: _stringOr(json['reality_sid'], ''),
      sni: sni,
      fingerprint: _stringOr(json['reality_fp'], AppConfig.realityFp),
      path: _stringOr(json['xhttp_path'], AppConfig.vlessPath),
    );
  }

  String toVlessUrl() {
    return 'vless://$uuid@$host:$port'
        '?security=${AppConfig.vlessSecurity}'
        '&type=${AppConfig.vlessType}'
        '&path=$path'
        '&pbk=${Uri.encodeComponent(publicKey)}'
        '&sni=${Uri.encodeComponent(sni)}'
        '&sid=${Uri.encodeComponent(shortId)}'
        '&fp=${Uri.encodeComponent(fingerprint)}'
        '#Revolt VPN';
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    throw FormatException('Missing required session field: $key');
  }

  static String _stringOr(Object? value, String fallback) {
    return value is String && value.isNotEmpty ? value : fallback;
  }

  static int _portOr(Object? value, int fallback) {
    final parsed = value is num ? value.toInt() : fallback;
    if (parsed <= 0 || parsed > 65535) {
      throw const FormatException('Invalid VLESS port');
    }
    return parsed;
  }
}
