import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class CryptoService {
  static const String _deviceIdPref = 'device_uuid';
  static const String _sessionNoncePref = 'session_auth_nonce';
  static const String _pendingSessionCandidatePref =
      'pending_session_candidate_nonce';
  static const String _sessionStopPendingPref = 'session_stop_pending';
  static const _storage = FlutterSecureStorage();
  static final RegExp _sessionNoncePattern = RegExp(r'^[0-9a-f]{32}$');

  /// Get or create a persistent device UUID for server-side session tracking.
  static Future<String> getDeviceId() async {
    final existing = await _storage.read(key: _deviceIdPref);
    if (existing != null) return existing;

    final newId = const Uuid().v4();
    await _storage.write(key: _deviceIdPref, value: newId);
    return newId;
  }

  /// Persist the current main-session possession token across app/process restarts.
  /// Promotion writes possession before clearing the pre-activation candidate. If the
  /// second write fails, both records remain, which is fail-closed: the active token is
  /// still retained and a later main flow must converge the stale candidate first.
  static Future<void> setSessionNonce(String nonce) async {
    _validateSessionNonce(nonce);
    await _storage.write(key: _sessionNoncePref, value: nonce);
    await _storage.delete(key: _pendingSessionCandidatePref);
  }

  /// Return only a canonical 128-bit session nonce. Corrupt legacy values are discarded.
  static Future<String?> getSessionNonce() async {
    final nonce = await _storage.read(key: _sessionNoncePref);
    if (nonce == null) return null;
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      await _storage.delete(key: _sessionNoncePref);
      return null;
    }
    return nonce;
  }

  static Future<void> clearSessionNonce() async {
    await _storage.delete(key: _sessionNoncePref);
  }

  /// Persist the exact server-acknowledged pre-activation capability independently
  /// from active possession so a process restart cannot silently forget an orphan.
  static Future<void> setPendingSessionCandidate(String nonce) async {
    _validateSessionNonce(nonce);
    await _storage.write(key: _pendingSessionCandidatePref, value: nonce);
  }

  static Future<String?> getPendingSessionCandidate() async {
    final nonce = await _storage.read(key: _pendingSessionCandidatePref);
    if (nonce == null) return null;
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      await _storage.delete(key: _pendingSessionCandidatePref);
      return null;
    }
    return nonce;
  }

  static Future<void> clearPendingSessionCandidate() async {
    await _storage.delete(key: _pendingSessionCandidatePref);
  }

  /// Persist an explicit user-requested server revocation until the server confirms it.
  /// This prevents a process restart or transient network failure from silently forgetting
  /// that the current possession token still needs to be revoked server-side.
  static Future<void> setSessionStopPending() async {
    await _storage.write(key: _sessionStopPendingPref, value: '1');
  }

  static Future<bool> isSessionStopPending() async {
    return await _storage.read(key: _sessionStopPendingPref) == '1';
  }

  static Future<void> clearSessionStopPending() async {
    await _storage.delete(key: _sessionStopPendingPref);
  }

  static void _validateSessionNonce(String nonce) {
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      throw ArgumentError.value(
        nonce,
        'nonce',
        'expected 128-bit lowercase hex',
      );
    }
  }
}
