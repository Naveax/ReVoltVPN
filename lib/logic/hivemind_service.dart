import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

  static Future<http.Response> directGet(Uri uri, {Duration timeout = const Duration(seconds: 5)}) {
    return http.get(uri, headers: {'User-Agent': _ua}).timeout(timeout);
  }

  static Future<http.Response> directPost(Uri uri, String body, {Duration timeout = const Duration(seconds: 5)}) {
    return http.post(uri, headers: {
      'Content-Type': 'application/json',
      'User-Agent': _ua,
    }, body: body).timeout(timeout);
  }

  static Future<http.Response> proxyGet(Uri uri, {Duration timeout = const Duration(seconds: 5)}) {
    return _proxyRequest('GET', uri, timeout: timeout);
  }

  static Future<http.Response> proxyPost(Uri uri, String body, {Duration timeout = const Duration(seconds: 5)}) {
    return _proxyRequest('POST', uri, body: body, timeout: timeout);
  }

  static Future<http.Response> _proxyRequest(String method, Uri uri,
      {String? body, Duration timeout = const Duration(seconds: 5)}) async {
    final socket = await Socket.connect('127.0.0.1', 10808, timeout: timeout);
    try {
      final target = uri.toString();
      final headers = <String, String>{
        'Host': '${uri.host}:${uri.port}',
        'User-Agent': _ua,
        'Accept': '*/*',
        'Connection': 'close',
      };
      if (body != null) {
        headers['Content-Type'] = 'application/json';
        headers['Content-Length'] = body.length.toString();
      }

      final reqBuf = StringBuffer();
      reqBuf.write('$method $target HTTP/1.1\r\n');
      headers.forEach((k, v) => reqBuf.write('$k: $v\r\n'));
      reqBuf.write('\r\n');
      if (body != null) reqBuf.write(body);

      socket.write(reqBuf.toString());
      await socket.flush();

      final response = await socket.fold<String>(
        '',
        (prev, chunk) => prev + String.fromCharCodes(chunk),
      ).timeout(timeout);

      final parts = response.split('\r\n\r\n');
      if (parts.length < 2) throw Exception('Invalid proxy response');
      final headerBlock = parts[0];
      final respBody = parts.sublist(1).join('\r\n\r\n');

      final headerLines = headerBlock.split('\r\n');
      final statusParts = headerLines[0].split(' ');
      final statusCode = int.parse(statusParts[1]);

      return http.Response(respBody, statusCode);
    } finally {
      socket.destroy();
    }
  }

  static void cancel() {
    _currentCallId++;
  }

  static void setExpectedNonce(String nonce) {
    _expectedNonce = nonce;
  }

  static Future<String> fetchConfigDirectly({
    void Function(int attempt, int total)? onAttempt,
    bool skipAdBypass = false,
  }) async {
    final deviceId = await CryptoService.getDeviceId();

    final callId = ++_currentCallId;
    final nonce = '${Random().nextInt(0x7FFFFFFF)}-${DateTime.now().millisecondsSinceEpoch}';
    _expectedNonce = nonce;
    debugPrint('[HivemindService] Call #$callId — nonce: $nonce');

    final url = _publicUrl('/session/status?device_id=$deviceId');

    if (!skipAdBypass) {
      try {
        final customData = jsonEncode({'device_id': deviceId, 'nonce': nonce});
        final fakeUrl = _publicUrl(
            '/admob/callback?signature=test&key_id=test&custom_data=${Uri.encodeComponent(customData)}');
        await directGet(fakeUrl, timeout: const Duration(seconds: 8));
      } catch (_) {}
    }

    const maxAttempts = 5;
    for (int i = 1; i <= maxAttempts; i++) {
      if (_currentCallId != callId) throw Exception('Cancelled');

      onAttempt?.call(i, maxAttempts);
      try {
        final response = await directGet(url);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);

          final serverNonce = data['nonce'] as String?;
          if (_expectedNonce != null && serverNonce != null && serverNonce != _expectedNonce) {
            debugPrint('[HivemindService] Nonce mismatch — retrying…');
          } else if (data['active'] == true && data['vless_uuid'] != null) {
            final vlessUuid = data['vless_uuid'];
            final vlessIp   = data['vless_ip'] ?? AppConfig.serverIp;
            final vlessPort = data['vless_port'] ?? 443;
            final pbk       = data['reality_pbk'] ?? '';
            final sid       = data['reality_sid'] ?? '';
            final sni       = data['reality_sni'];
            if (sni == null) throw Exception('Server did not provide reality_sni');
            final fp        = data['reality_fp']  ?? AppConfig.realityFp;
            final xhttpPath = data['xhttp_path']  ?? AppConfig.vlessPath;

            final vlessUrl = 'vless://$vlessUuid@$vlessIp:$vlessPort'
                '?security=${AppConfig.vlessSecurity}'
                '&type=${AppConfig.vlessType}'
                '&path=$xhttpPath'
                '&pbk=${Uri.encodeComponent(pbk)}'
                '&sni=${Uri.encodeComponent(sni)}'
                '&sid=${Uri.encodeComponent(sid)}'
                '&fp=${Uri.encodeComponent(fp)}'
                '#Revolt VPN';
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

  static Future<bool> checkHealth() async {
    try {
      final url = Uri.parse('${AppConfig.hivemindApiPublic}/health');
      final response = await directGet(url, timeout: const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> verifySession() async {
    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = _tunnelUrl('/session/status?device_id=$deviceId');
      final response = await proxyGet(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['active'] == true;
      }
    } catch (_) {}
    return false;
  }

  // Idle sessions are culled server-side by the management loop
  // after 2 minutes of no /status polls (user disconnected).
  static void disconnectAndCleanup() {}

  // ── URL builders ──────────────────────────────────────────────────

  static Uri _publicUrl(String path) =>
      Uri.parse('${AppConfig.hivemindApiPublic}$path');

  static Uri _tunnelUrl(String path) =>
      Uri.parse('${AppConfig.hivemindApiBase}$path');
}
