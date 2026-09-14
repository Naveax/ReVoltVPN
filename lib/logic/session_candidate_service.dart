import 'dart:convert';

import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

class SessionCandidateService {
  static const _sessionNonceHeader = 'X-RevoltVPN-Session-Nonce';
  static final RegExp _canonicalNonce = RegExp(r'^[0-9a-f]{32}$');

  static Uri _candidateUrl() {
    final base = Uri.parse(AppConfig.hivemindApiPublic);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$basePath/session/candidate',
      query: null,
      fragment: null,
    );
  }

  /// Reserve the exact main-session possession nonce before an ad is shown.
  /// A reservation is not an active credential and is never persisted locally.
  static Future<bool> register(String nonce) async {
    if (!_canonicalNonce.hasMatch(nonce)) return false;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final response = await HivemindService.directPost(
        _candidateUrl(),
        body: jsonEncode(<String, String>{'device_id': deviceId}),
        timeout: const Duration(seconds: 4),
        headers: <String, String>{_sessionNonceHeader: nonce},
      );
      if (response.statusCode != 200) return false;

      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> && decoded['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}
