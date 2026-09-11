import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class CryptoService {
  static const String _deviceIdPref = 'device_uuid';
  static const String _sessionNoncePref = 'session_auth_nonce';
  static const String _pendingMainSessionNoncePref =
      'pending_main_session_nonce';
  static const String _sessionStopPendingPref = 'session_stop_pending';
  static const _storage = FlutterSecureStorage();

  static final RegExp _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final RegExp _sessionNoncePattern = RegExp(r'^[0-9a-f]{32}$');

  /// Get or create a persistent device UUID for server-side session tracking.
  /// Corrupted or tampered storage values are replaced instead of being sent
  /// to the public API as arbitrary query data. Session credentials are bound
  /// to the device UUID, so a replacement identity also drops all old
  /// device-bound authorization state.
  static Future<String> getDeviceId() async {
    final existing = await _storage.read(key: _deviceIdPref);
    if (existing != null && _uuidV4.hasMatch(existing)) return existing;

    await _clearDeviceBoundSessionState();
    final newId = const Uuid().v4();
    await _storage.write(key: _deviceIdPref, value: newId);
    return newId;
  }

  static Future<void> _clearDeviceBoundSessionState() async {
    await _storage.delete(key: _sessionNoncePref);
    await _storage.delete(key: _pendingMainSessionNoncePref);
    await _storage.delete(key: _sessionStopPendingPref);
  }

  static void _requireSessionNonce(String nonce) {
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      throw ArgumentError.value(
        nonce,
        'nonce',
        'expected 128-bit lowercase hex',
      );
    }
  }

  /// Persist the current main-session possession token across app/process restarts.
  static Future<void> setSessionNonce(String nonce) async {
    _requireSessionNonce(nonce);
    await _storage.write(key: _sessionNoncePref, value: nonce);
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

  /// A main-ad SSV candidate is not an authorized session token yet. Keep it
  /// separately so a delayed Google callback can be recovered after an app
  /// restart or a bounded confirmation timeout without minting a new nonce.
  static Future<void> setPendingMainSessionNonce(String nonce) async {
    _requireSessionNonce(nonce);
    await _storage.write(key: _pendingMainSessionNoncePref, value: nonce);
  }

  static Future<String?> getPendingMainSessionNonce() async {
    final nonce = await _storage.read(key: _pendingMainSessionNoncePref);
    if (nonce == null) return null;
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      await _storage.delete(key: _pendingMainSessionNoncePref);
      return null;
    }
    return nonce;
  }

  static Future<void> clearPendingMainSessionNonce() async {
    await _storage.delete(key: _pendingMainSessionNoncePref);
  }

  /// Compare before deleting so cleanup from an older ad flow can never erase
  /// a newer candidate that reused the same storage slot.
  static Future<void> clearPendingMainSessionNonceIfMatches(String nonce) async {
    _requireSessionNonce(nonce);
    final current = await getPendingMainSessionNonce();
    if (current == nonce) {
      await _storage.delete(key: _pendingMainSessionNoncePref);
    }
  }

  /// Persist an explicit user-requested server revocation until the server confirms it.
  /// A pending SSV candidate is cancelled under the same durable barrier so a
  /// delayed callback can never be recovered into a connectable session after
  /// the user has explicitly asked to disconnect.
  static Future<void> setSessionStopPending() async {
    await _storage.write(key: _sessionStopPendingPref, value: '1');
    await clearPendingMainSessionNonce();
  }

  static Future<bool> isSessionStopPending() async {
    final pending = await _storage.read(key: _sessionStopPendingPref) == '1';
    if (pending) {
      // Crash recovery for the narrow window between persisting the stop marker
      // and deleting a previously-staged SSV candidate.
      await clearPendingMainSessionNonce();
    }
    return pending;
  }

  static Future<void> clearSessionStopPending() async {
    await _storage.delete(key: _sessionStopPendingPref);
  }
}
