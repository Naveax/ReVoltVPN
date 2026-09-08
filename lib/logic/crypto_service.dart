import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class CryptoService {
  static const String _deviceIdPref = 'device_uuid';
  static const String _sessionNoncePref = 'session_auth_nonce';
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
  static Future<void> setSessionNonce(String nonce) async {
    if (!_sessionNoncePattern.hasMatch(nonce)) {
      throw ArgumentError.value(nonce, 'nonce', 'expected 128-bit lowercase hex');
    }
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
}
