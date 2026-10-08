import 'package:uuid/uuid.dart';

/// The wire protocol still calls this a device_id, but it is a rotating,
/// server-unlinkable client epoch pseudonym, not a hardware identifier.
abstract class ClientEpochStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class ClientEpochIdentity {
  static const identityKey = 'device_uuid'; // Preserve deployed credentials.
  static const rotationReadyKey = 'client_epoch_rotation_ready';
  static const sessionNonceKey = 'session_auth_nonce';
  static const candidateKey = 'pending_session_candidate_nonce';
  static const stopPendingKey = 'session_stop_pending';

  final ClientEpochStorage _storage;
  final String Function() _newUuid;
  Future<void> _tail = Future<void>.value();
  static final RegExp _uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  String _checkedNewId(String? previous) {
    final next = _newUuid();
    if (!_uuidV4.hasMatch(next) || next == previous) {
      throw StateError('Client epoch UUIDv4 generation failed');
    }
    return next;
  }

  ClientEpochIdentity(
    this._storage, {
    String Function()? newUuid,
  }) : _newUuid = newUuid ?? (const Uuid().v4);

  /// Serialize accesses to the identity itself within this process.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = previous.catchError((Object _) {});
    final result = done.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> current() => _exclusive(() async {
        final existing = await _storage.read(identityKey);
        if (existing != null) {
          if (!_uuidV4.hasMatch(existing)) {
            throw StateError('Invalid stored client epoch');
          }
          return existing;
        }
        final fresh = _checkedNewId(null);
        await _storage.write(identityKey, fresh);
        return fresh;
      });

  /// Only call after a server-authenticated terminal/stop acknowledgement.
  /// An offline timeout or a local disconnect does NOT make an epoch retirable.
  Future<void> acknowledgeTerminal() => _exclusive(() async {
        await _storage.write(rotationReadyKey, '1');
      });

  /// Rotate at the start of the next main-session admission, not in the
  /// middle of an existing authenticated request. Never persist a mapping.
  Future<bool> rotateBeforeNewSession() => _exclusive(() async {
        if (await _storage.read(rotationReadyKey) != '1') return false;
        for (final key in [sessionNonceKey, candidateKey, stopPendingKey]) {
          if (await _storage.read(key) != null) return false;
        }
        // Consume first. If a process crashes here, privacy rotation is
        // deferred rather than repeating and orphaning a newly minted epoch.
        final previous = await _storage.read(identityKey);
        if (previous == null || !_uuidV4.hasMatch(previous)) {
          throw StateError('Missing or invalid old client epoch');
        }
        final replacement = _checkedNewId(previous);
        await _storage.delete(rotationReadyKey);
        await _storage.write(identityKey, replacement);
        return true;
      });
}
