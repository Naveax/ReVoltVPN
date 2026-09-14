import 'dart:convert';

import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

class SessionCandidateService {
  static const _sessionNonceHeader = 'X-RevoltVPN-Session-Nonce';
  static final RegExp _canonicalNonce = RegExp(r'^[0-9a-f]{32}$');

  static Uri _publicUrl(String suffix) {
    final base = Uri.parse(AppConfig.hivemindApiPublic);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$basePath/$suffix',
      query: null,
      fragment: null,
    );
  }

  /// Reserve the exact main-session possession nonce before an ad is shown.
  /// The acknowledged candidate is stored separately from the active session
  /// credential so a disconnect or process restart can still revoke it exactly.
  static Future<bool> register(String nonce) async {
    if (!_canonicalNonce.hasMatch(nonce)) return false;

    try {
      final existing = await CryptoService.getPendingSessionCandidate();
      if (existing != null && existing != nonce) return false;

      final deviceId = await CryptoService.getDeviceId();
      final response = await HivemindService.directPost(
        _publicUrl('session/candidate'),
        body: jsonEncode(<String, String>{'device_id': deviceId}),
        timeout: const Duration(seconds: 4),
        headers: <String, String>{_sessionNonceHeader: nonce},
      );
      if (response.statusCode != 200) return false;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        return false;
      }

      try {
        await CryptoService.setPendingSessionCandidate(nonce);
        return true;
      } catch (_) {
        await _cancelExact(deviceId, nonce);
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isCurrent(String nonce) async {
    if (!_canonicalNonce.hasMatch(nonce)) return false;
    return await CryptoService.getPendingSessionCandidate() == nonce;
  }

  /// Cancel an acknowledged but not-yet-confirmed candidate. stopSession()
  /// advances Hivemind's mutation epoch synchronously and persists the durable
  /// stop marker before reading the credential. CryptoService exposes the pending
  /// candidate to that stop path only while the explicit stop marker is present.
  static Future<bool> cancelPending() async {
    final candidate = await CryptoService.getPendingSessionCandidate();
    if (candidate == null) return true;

    try {
      final result = await HivemindService.stopSession();
      return result != SessionStopResult.retryNeeded;
    } catch (_) {
      return false;
    }
  }

  /// Before a new main-ad flow, converge any reservation left by a crash,
  /// dismissal, failed show, or disconnect before accepting another candidate.
  static Future<bool> recoverOrphanedReservation() async {
    final candidate = await CryptoService.getPendingSessionCandidate();
    if (candidate == null) return true;
    return cancelPending();
  }

  static Future<void> _cancelExact(String deviceId, String nonce) async {
    try {
      await HivemindService.directPost(
        _publicUrl('session/stop'),
        body: jsonEncode(<String, String>{'device_id': deviceId}),
        timeout: const Duration(seconds: 4),
        headers: <String, String>{_sessionNonceHeader: nonce},
      );
    } catch (_) {
      // The ad has not been shown yet, so no SSV callback can activate this
      // untracked reservation. It expires on the server's fixed TTL.
    }
  }
}
