import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:revoltvpn/logic/client_epoch_identity.dart';

class CryptoService {
  static const String _sessionNoncePref = 'session_auth_nonce';
  static const String _pendingSessionCandidatePref =
      'pending_session_candidate_nonce';
  static const String _sessionStopPendingPref = 'session_stop_pending';
  static const _storage = FlutterSecureStorage();
  static final ClientEpochIdentity _epoch =
      ClientEpochIdentity(_SecureEpochStorage(_storage));
  static final RegExp _sessionNoncePattern = RegExp(r'^[0-9a-f]{32}$');

  /// Current server pseudonym; legacy wire field name is device_id.
  static Future<String> getDeviceId() => _epoch.current();

  /// Call only after a server-authenticated final session state.
  static Future<void> acknowledgeClientEpochTerminal() =>
      _epoch.acknowledgeTerminal();

  /// Atomically claim a new main candidate and any eligible epoch rotation.
  /// Returns the exact pseudonym to use for the server registration request.
  static Future<String?> beginMainSessionCandidate(String nonce) {
    _validateSessionNonce(nonce);
    return _epoch.beginCandidateReservation(nonce);
  }

  /// Persist the current main-session possession token across app/process restarts.
  /// Promotion writes possession before clearing the pre-activation candidate. If the
  /// second write fails, both records remain, which is fail-closed: the active token is
  /// still retained and a later main flow must converge the stale candidate first.
  static Future<void> setSessionNonce(String nonce) async {
    _validateSessionNonce(nonce);
    await _epoch.synchronizedStorage(() async {
      await _storage.write(key: _sessionNoncePref, value: nonce);
      await _storage.delete(key: _pendingSessionCandidatePref);
    });
  }

  /// Return only a canonical 128-bit session nonce. Corrupt values must stay
  /// durable: deleting unknown possession can orphan a live server credential.
  static Future<String?> getSessionNonce() =>
      _epoch.synchronizedStorage(() async {
        final nonce = await _storage.read(key: _sessionNoncePref);
        if (nonce == null) return null;
        if (!_sessionNoncePattern.hasMatch(nonce)) {
          // The atomic admission gate observes this non-null record and
          // refuses any new identity/candidate until it is reconciled.
          return null;
        }
        return nonce;
      });

  static Future<void> clearSessionNonce() =>
      _epoch.synchronizedStorage(() => _storage.delete(key: _sessionNoncePref));

  // Candidate creation is deliberately only exposed through
  // beginMainSessionCandidate. A separate setter would bypass the atomic
  // rotate-and-reserve gate and reintroduce the two-admission race.

  static Future<String?> getPendingSessionCandidate() =>
      _epoch.synchronizedStorage(() async {
        final nonce = await _storage.read(key: _pendingSessionCandidatePref);
        if (nonce == null) return null;
        if (!_sessionNoncePattern.hasMatch(nonce)) {
          // A malformed candidate can still correspond to a delayed SSV.
          // Never silently remove the durable ownership blocker.
          return null;
        }
        return nonce;
      });

  static Future<void> clearPendingSessionCandidate() =>
      _epoch.synchronizedStorage(
          () => _storage.delete(key: _pendingSessionCandidatePref));

  /// Persist an explicit user-requested server revocation until the server confirms it.
  /// This prevents a process restart or transient network failure from silently forgetting
  /// that the current possession token still needs to be revoked server-side.
  static Future<void> setSessionStopPending() => _epoch.synchronizedStorage(
      () => _storage.write(key: _sessionStopPendingPref, value: '1'));

  static Future<bool> isSessionStopPending() => _epoch.synchronizedStorage(
      () async => await _storage.read(key: _sessionStopPendingPref) == '1');

  static Future<void> clearSessionStopPending() => _epoch
      .synchronizedStorage(() => _storage.delete(key: _sessionStopPendingPref));

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

class _SecureEpochStorage implements ClientEpochStorage {
  final FlutterSecureStorage _storage;
  const _SecureEpochStorage(this._storage);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
