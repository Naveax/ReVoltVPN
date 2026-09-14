import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class CryptoService {
  static const String _deviceIdPref = 'device_uuid';
  static const String _sessionNoncePref = 'session_auth_nonce';
  static const String _pendingSessionCandidatePref = 'pending_session_candidate_nonce';
  static const String _sessionStopPendingPref = 'session_stop_pending';
  static const _storage = FlutterSecureStorage();

  static final RegExp _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final RegExp _sessionNoncePattern = RegExp(r'^[0-9a-f]{32}$');

  /// Get or create a persistent device UUID for server-side session tracking.
  /// Corrupted or tampered storage values are replaced instead of being sent
  /// to the public API as arbitrary query data.
  static Future<String> getDeviceId() async {
    final existing = await _storage.read(key: _deviceIdPref);
    if (existing != null && _uuidV4.hasMatch(existing)) return existing;

    final newId = const Uuid().v4();
    await _storage.write(key: _deviceIdPref, value: newId);
    return newId;
  }

  /// Persist the current main-session possession token across app/process restarts.
  /// Once the server-confirmed token is durable, its pre-activation reservation is
  /// no longer needed and is removed from the pending slot.
  static Future<void> setSessionNonce(String nonce) async {
    _validateSessionNonce(nonce);
    await _storage.write(key: _sessionNoncePref, value: nonce);
    await _storage.delete(key: _pendingSessionCandidatePref);
  }

  /// Return only a canonical 128-bit session nonce. During an explicit pending
  /// stop, a pre-activation candidate is also an exact revocation capability, so
  /// the stop path can cancel it even before Google SSV activates a session.
  static Future<String?> getSessionNonce() async {
    final nonce = await _readCanonicalNonce(_sessionNoncePref);
    if (nonce != null) return nonce;

    if (await isSessionStopPending()) {
      return _readCanonicalNonce(_pendingSessionCandidatePref);
    }
    return null;
  }

  static Future<void> clearSessionNonce() async {
    await _storage.delete(key: _sessionNoncePref);
    await _storage.delete(key: _pendingSessionCandidatePref);
  }

  /// Durably remember an acknowledged server reservation without treating it as
  /// an active session credential. This lets explicit stop/restart recovery cancel
  /// the exact nonce if the app exits or disconnects before SSV confirmation.
  static Future<void> setPendingSessionCandidate(String nonce) async {
    _validateSessionNonce(nonce);
    await _storage.write(key: _pendingSessionCandidatePref, value: nonce);
  }

  static Future<String?> getPendingSessionCandidate() {
    return _readCanonicalNonce(_pendingSessionCandidatePref);
  }

  static Future<void> clearPendingSessionCandidate() async {
    await _storage.delete(key: _pendingSessionCandidatePref);
  }

  /// Persist an explicit user-requested server revocation until the server confirms it.
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

  static Future<String?> _readCanonicalNonce(String key) async {
    final nonce = await _storage.read(key: key);
    if (nonce == null) return null;
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      await _storage.delete(key: key);
      return null;
    }
    return nonce;
  }
}
