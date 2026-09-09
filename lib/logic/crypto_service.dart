import 'package:flutter/foundation.dart';
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

    void release() {
      if (identical(_deviceIdOperation, operation)) {
        _deviceIdOperation = null;
      }
    }

    // Observe completion without replacing the Future returned to callers and
    // without creating a second unhandled error chain on storage failure.
    operation.then<void>(
      (_) => release(),
      onError: (Object _, StackTrace __) => release(),
    );
    return operation;
  }

  @visibleForTesting
  static String? canonicalizeDeviceId(String? value) {
    if (value == null || !_uuidV4.hasMatch(value)) return null;
    return value.toLowerCase();
  }

  static Future<String> _loadOrCreateDeviceId() async {
    final existing = await _storage.read(key: _deviceIdPref);
    final canonical = canonicalizeDeviceId(existing);
    if (canonical != null) {
      if (canonical != existing) {
        await _storage.write(key: _deviceIdPref, value: canonical);
      }
      return canonical;
    }

    final newId = const Uuid().v4().toLowerCase();
    await _storage.write(key: _deviceIdPref, value: newId);
    return newId;
  }
}
