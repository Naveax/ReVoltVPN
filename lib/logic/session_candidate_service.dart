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
      final stopEpoch = await CryptoService.getSessionStopEpoch();
      if (await CryptoService.isSessionStopPending()) return false;

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

      if (!await _registrationStillCurrent(stopEpoch)) {
        await _cancelExact(deviceId, nonce);
        return false;
      }

      try {
        await CryptoService.setPendingSessionCandidate(nonce);
      } catch (_) {
        await _cancelExact(deviceId, nonce);
        return false;
      }

      if (!await _registrationStillCurrent(stopEpoch)) {
        final cancelled = await _cancelExact(deviceId, nonce);
        if (cancelled) {
          await CryptoService.clearPendingSessionCandidate();
        } else if (!await CryptoService.isSessionStopPending()) {
          try {
            await CryptoService.setSessionStopPending();
          } catch (_) {
            // The pending candidate remains durable and blocks another main flow.
          }
        }
        return false;
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isCurrent(String nonce) async {
    if (!_canonicalNonce.hasMatch(nonce)) return false;
    try {
      if (await CryptoService.isSessionStopPending()) return false;
      return await CryptoService.getPendingSessionCandidate() == nonce;
    } catch (_) {
      return false;
    }
  }

  /// Cancel an acknowledged but not-yet-confirmed candidate directly with the
  /// exact nonce. The same endpoint also revokes it if Google SSV won the race
  /// and already promoted that nonce to a provisioning/active generation.
  static Future<bool> cancelPending() async {
    final candidate = await CryptoService.getPendingSessionCandidate();
    if (candidate == null) return true;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final cancelled = await _cancelExact(deviceId, candidate);
      if (!cancelled) {
        if (!await CryptoService.isSessionStopPending()) {
          await CryptoService.setSessionStopPending();
        }
        return false;
      }

      await CryptoService.clearPendingSessionCandidate();
      if (await CryptoService.isSessionStopPending() &&
          await CryptoService.getSessionNonce() == null) {
        await CryptoService.clearSessionStopPending();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Before a new main-ad flow, converge any reservation left by a crash,
  /// dismissal, failed show, or disconnect before accepting another candidate.
  static Future<bool> recoverOrphanedReservation() async {
    try {
      final candidate = await CryptoService.getPendingSessionCandidate();
      if (candidate == null) return true;
      return await cancelPending();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _registrationStillCurrent(int stopEpoch) async {
    if (await CryptoService.isSessionStopPending()) return false;
    return await CryptoService.getSessionStopEpoch() == stopEpoch;
  }

  static Future<bool> _cancelExact(String deviceId, String nonce) async {
    try {
      final response = await HivemindService.directPost(
        _publicUrl('session/stop'),
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
