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

  /// Share the identity gate with all durable session/candidate/stop records.
  /// No external I/O is allowed inside this callback beyond secure storage;
  /// notably, never hold this gate during a network request.
  Future<T> synchronizedStorage<T>(Future<T> Function() action) =>
      _exclusive(action);

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

  /// Reserve exactly one candidate and its epoch together, before any network I/O.
  /// A separate rotate-then-reserve pair is unsafe: another admission could
  /// claim a nonce for the previous or newly minted epoch between those awaits.
  /// Return null when possession, pending cancellation or another candidate
  /// still exists; never overwrite a durable candidate or stop intent.
  Future<String?> beginCandidateReservation(String nonce) =>
      _exclusive(() async {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce)) {
          throw ArgumentError.value(nonce, 'nonce', 'invalid candidate nonce');
        }
        for (final key in [sessionNonceKey, candidateKey, stopPendingKey]) {
          if (await _storage.read(key) != null) return null;
        }
        final existing = await _storage.read(identityKey);
        if (existing != null && !_uuidV4.hasMatch(existing)) {
          throw StateError('Invalid stored client epoch');
        }
        var identity = existing ?? _checkedNewId(null);
        if (await _storage.read(rotationReadyKey) == '1') {
          // A terminal marker with no old pseudonym is an inconsistent store,
          // not permission to silently create an unrelated replacement.
          if (existing == null) {
            throw StateError('Missing or invalid old client epoch');
          }
          // Validate/generate before consuming the marker, so a bad RNG value
          // cannot silently erase the only evidence authorizing rotation.
          identity = _checkedNewId(existing);
          await _storage.delete(rotationReadyKey);
        }
        // Persist the identity before the nonce, so any crash after nonce
        // persistence still leaves one unambiguous owned epoch.
        if (identity != existing) await _storage.write(identityKey, identity);
        await _storage.write(candidateKey, nonce);
        return identity;
      });

  /// Promote the exact server-confirmed candidate under the same gate that
  /// protects reservations, stop intent and all durable nonce mutations.
  /// Writing possession first intentionally retains both records on a crash.
  /// Stop intent is never cleared by promotion: a concurrent disconnect must
  /// still revoke the promoted capability before allowing a new admission.
  Future<bool> promoteCandidate(String nonce) => _exclusive(() async {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce)) return false;
        if (await _storage.read(candidateKey) != nonce) return false;
        final currentNonce = await _storage.read(sessionNonceKey);
        if (currentNonce != null && currentNonce != nonce) return false;
        await _storage.write(sessionNonceKey, nonce);
        await _storage.delete(candidateKey);
        return true;
      });

  /// Remove only the exact cancelled/absent candidate. A stale response must
  /// not delete a later reservation or a token that was already promoted.
  Future<bool> clearCandidateIfMatches(String nonce) => _exclusive(() async {
        if (await _storage.read(candidateKey) != nonce) return false;
        await _storage.delete(candidateKey);
        return true;
      });

  /// Whether a durable capability may still be owned, even when malformed.
  /// Keep this and the stop-marker deletion inside one lock to prevent
  /// treating an in-flight promotion as proof of an inactive session.
  Future<bool> clearStopIntentIfNoOwnership() => _exclusive(() async {
        if (await _storage.read(sessionNonceKey) != null ||
            await _storage.read(candidateKey) != null) return false;
        await _storage.delete(stopPendingKey);
        return true;
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
