import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class CryptoService {
  static const String _deviceIdPref = 'device_uuid';
  static const _storage = FlutterSecureStorage();
  static Future<String>? _deviceIdOperation;
  static final RegExp _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Get or create a persistent device UUID for server-side session tracking.
  /// Corrupted or tampered storage values are replaced instead of being sent
  /// to the public API as arbitrary query data.
  ///
  /// Creation is single-flight so concurrent startup/session callers cannot
  /// observe different freshly-generated identifiers before secure storage is
  /// populated.
  static Future<String> getDeviceId() {
    final active = _deviceIdOperation;
    if (active != null) return active;

    final operation = _loadOrCreateDeviceId();
    _deviceIdOperation = operation;
    operation.whenComplete(() {
      if (identical(_deviceIdOperation, operation)) {
        _deviceIdOperation = null;
      }
    });
    return operation;
  }

  static Future<String> _loadOrCreateDeviceId() async {
    final existing = await _storage.read(key: _deviceIdPref);
    if (existing != null && _uuidV4.hasMatch(existing)) return existing;

    final newId = const Uuid().v4();
    await _storage.write(key: _deviceIdPref, value: newId);
    return newId;
  }
}
