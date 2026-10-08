import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/client_epoch_identity.dart';

class _MemoryEpochStorage implements ClientEpochStorage {
  final values = <String, String>{};
  bool rejectIdentityWrite = false;
  bool rejectCandidateWrite = false;
  bool rejectNonceWrite = false;
  bool rejectRotationDelete = false;
  bool rejectRotationWrite = false;
  bool rejectNonceDelete = false;
  bool rejectStopDelete = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if ((rejectIdentityWrite && key == ClientEpochIdentity.identityKey) ||
        (rejectRotationWrite && key == ClientEpochIdentity.rotationReadyKey) ||
        (rejectCandidateWrite && key == ClientEpochIdentity.candidateKey) ||
        (rejectNonceWrite && key == ClientEpochIdentity.sessionNonceKey)) {
      throw StateError('simulated secure storage failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if ((rejectRotationDelete && key == ClientEpochIdentity.rotationReadyKey) ||
        (rejectNonceDelete && key == ClientEpochIdentity.sessionNonceKey) ||
        (rejectStopDelete && key == ClientEpochIdentity.stopPendingKey)) {
      throw StateError('simulated marker deletion failure');
    }
    values.remove(key);
  }
}

void main() {
  const oldId = '12345678-1234-4234-8234-123456789abc';
  const nextId = 'deadbeef-abcd-4000-8000-123456789abc';
  const candidate1 = '11111111111111111111111111111111';
  const candidate2 = '22222222222222222222222222222222';

  test('confirmed exact stop receipt clears only its owned capability',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = candidate1
      ..values[ClientEpochIdentity.stopPendingKey] = '1';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.completeAcknowledgedSessionStop(candidate1), true);
    expect(await epochs.readSessionNonce(), null);
    expect(store.values.containsKey(ClientEpochIdentity.stopPendingKey), false);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(await epochs.beginCandidateReservation(candidate2), nextId);
    expect(store.values[ClientEpochIdentity.identityKey], nextId);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate2);
  });

  test('stale stop receipt cannot erase a newer active nonce or stop intent',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = candidate1
      ..values[ClientEpochIdentity.stopPendingKey] = '1';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.completeAcknowledgedSessionStop(candidate1), true);
    expect(await epochs.beginCandidateReservation(candidate2), nextId);
    expect(await epochs.promoteCandidate(candidate2), true);
    await epochs.synchronizedStorage(
        () => store.write(ClientEpochIdentity.stopPendingKey, '1'));
    expect(await epochs.completeAcknowledgedSessionStop(candidate1), false);
    expect(await epochs.readSessionNonce(), candidate2);
    expect(store.values[ClientEpochIdentity.stopPendingKey], '1');
    expect(
        store.values.containsKey(ClientEpochIdentity.rotationReadyKey), false);
    expect(store.values[ClientEpochIdentity.identityKey], nextId);
  });

  test('stop receipt refuses unresolved candidate and corrupt markers',
      () async {
    for (final blocker in [
      ClientEpochIdentity.candidateKey,
      ClientEpochIdentity.stopPendingKey,
      ClientEpochIdentity.rotationReadyKey,
    ]) {
      final store = _MemoryEpochStorage()
        ..values[ClientEpochIdentity.identityKey] = oldId
        ..values[ClientEpochIdentity.sessionNonceKey] = candidate1
        ..values[ClientEpochIdentity.stopPendingKey] = '1';
      store.values[blocker] = blocker == ClientEpochIdentity.candidateKey
          ? candidate2
          : 'malformed';
      final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
      expect(await epochs.completeAcknowledgedSessionStop(candidate1), false);
      expect(await epochs.readSessionNonce(), candidate1);
      expect(store.values[blocker], isNotNull);
      expect(store.values.containsKey(ClientEpochIdentity.rotationReadyKey),
          blocker == ClientEpochIdentity.rotationReadyKey);
    }
  });

  test('rotation-marker write failure retains possession and pending stop',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = candidate1
      ..values[ClientEpochIdentity.stopPendingKey] = '1'
      ..rejectRotationWrite = true;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await expectLater(epochs.completeAcknowledgedSessionStop(candidate1),
        throwsA(isA<StateError>()));
    expect(await epochs.readSessionNonce(), candidate1);
    expect(store.values[ClientEpochIdentity.stopPendingKey], '1');
    expect(
        store.values.containsKey(ClientEpochIdentity.rotationReadyKey), false);
    expect(await epochs.beginCandidateReservation(candidate2), null);
    store.rejectRotationWrite = false;
    expect(await epochs.completeAcknowledgedSessionStop(candidate1), true);
  });

  test('failed nonce deletion keeps rotation proof and owner across restart',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = candidate1
      ..values[ClientEpochIdentity.stopPendingKey] = '1'
      ..rejectNonceDelete = true;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await expectLater(epochs.completeAcknowledgedSessionStop(candidate1),
        throwsA(isA<StateError>()));
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(store.values[ClientEpochIdentity.sessionNonceKey], candidate1);
    expect(await epochs.beginCandidateReservation(candidate2), null);
    store.rejectNonceDelete = false;
    final restarted = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await restarted.completeAcknowledgedSessionStop(candidate1), true);
    expect(await restarted.beginCandidateReservation(candidate2), nextId);
  });

  test('failed pending-stop deletion never allows a new candidate', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = candidate1
      ..values[ClientEpochIdentity.stopPendingKey] = '1'
      ..rejectStopDelete = true;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await expectLater(epochs.completeAcknowledgedSessionStop(candidate1),
        throwsA(isA<StateError>()));
    expect(await epochs.readSessionNonce(), null);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(store.values[ClientEpochIdentity.stopPendingKey], '1');
    expect(await epochs.beginCandidateReservation(candidate2), null);
    store.rejectStopDelete = false;
    final restarted = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await restarted.clearStopIntentIfNoOwnership(), true);
    expect(await restarted.beginCandidateReservation(candidate2), nextId);
  });

  test('receipt and candidate promotion serialize without erasing candidate',
      () async {
    for (final stopFirst in [true, false]) {
      final store = _MemoryEpochStorage()
        ..values[ClientEpochIdentity.identityKey] = oldId
        ..values[ClientEpochIdentity.candidateKey] = candidate1
        ..values[ClientEpochIdentity.stopPendingKey] = '1';
      final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
      final outcomes = await Future.wait(stopFirst
          ? [
              epochs.completeAcknowledgedSessionStop(candidate1),
              epochs.promoteCandidate(candidate1),
            ]
          : [
              epochs.promoteCandidate(candidate1),
              epochs.completeAcknowledgedSessionStop(candidate1),
            ]);
      expect(outcomes, stopFirst ? [false, true] : [true, true]);
      if (stopFirst) {
        expect(await epochs.readSessionNonce(), candidate1);
        expect(await epochs.completeAcknowledgedSessionStop(candidate1), true);
      }
      expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
      expect(
          store.values.containsKey(ClientEpochIdentity.sessionNonceKey), false);
    }
  });

  test('durable nonce reader observes promotion and authenticated teardown',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.readSessionNonce(), null);
    expect(await epochs.beginCandidateReservation(candidate1), oldId);
    expect(await epochs.readSessionNonce(), null);
    expect(await epochs.promoteCandidate(candidate1), true);
    expect(await epochs.readSessionNonce(), candidate1);
    await epochs.synchronizedStorage(
        () => store.delete(ClientEpochIdentity.sessionNonceKey));
    expect(await epochs.readSessionNonce(), null);
    final restarted = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await restarted.readSessionNonce(), null);
  });

  test('serialized nonce reader cannot retain stale possession after deletion',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = candidate1;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    // Read, revoke, and read again: all durable operations use one gate.
    final firstRead = epochs.readSessionNonce();
    final revoke = epochs.synchronizedStorage(
        () => store.delete(ClientEpochIdentity.sessionNonceKey));
    final afterRevoke = epochs.readSessionNonce();
    expect(await firstRead, candidate1);
    await revoke;
    expect(await afterRevoke, null);
    expect(await epochs.readSessionNonce(), null);
  });

  test('malformed possession is retained and blocks subsequent admission',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.sessionNonceKey] = 'invalid-durable-nonce';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.readSessionNonce(), null);
    expect(store.values[ClientEpochIdentity.sessionNonceKey],
        'invalid-durable-nonce');
    expect(await epochs.beginCandidateReservation(candidate1), null);
    final restarted = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await restarted.readSessionNonce(), null);
    expect(await restarted.beginCandidateReservation(candidate2), null);
  });

  test('fresh install without durable ownership can initialize one epoch',
      () async {
    final store = _MemoryEpochStorage();
    final epochs = ClientEpochIdentity(store, newUuid: () => oldId);
    expect(await epochs.current(), oldId);
    expect(store.values[ClientEpochIdentity.identityKey], oldId);
    expect(await epochs.beginCandidateReservation(candidate1), oldId);
  });

  test('missing epoch with any durable ownership fails closed across restart',
      () async {
    for (final key in [
      ClientEpochIdentity.sessionNonceKey,
      ClientEpochIdentity.candidateKey,
      ClientEpochIdentity.stopPendingKey,
      ClientEpochIdentity.rotationReadyKey,
    ]) {
      final store = _MemoryEpochStorage()..values[key] = 'unresolved';
      final epochs = ClientEpochIdentity(store, newUuid: () => oldId);
      await expectLater(epochs.current(), throwsA(isA<StateError>()),
          reason: 'missing identity must not mint a new ID with $key');
      expect(store.values.containsKey(ClientEpochIdentity.identityKey), false);
      final restarted = ClientEpochIdentity(store, newUuid: () => nextId);
      await expectLater(restarted.current(), throwsA(isA<StateError>()));
      expect(store.values[key], 'unresolved');
      expect(store.values.containsKey(ClientEpochIdentity.identityKey), false);
    }
  });

  test('unowned corrupted stop marker cannot silently disappear', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.stopPendingKey] = 'garbage';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.clearStopIntentIfNoOwnership(), false);
    expect(await epochs.beginCandidateReservation(candidate1), null);
    expect(store.values[ClientEpochIdentity.stopPendingKey], 'garbage');
    expect(await epochs.current(), oldId);
  });

  test('missing identity and rejected concurrent admission cannot mint a UUID',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.candidateKey] = candidate1;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    final reads = Future.wait([
      epochs
          .current()
          .then<Object?>((v) => v, onError: (Object error) => error),
      epochs.beginCandidateReservation(candidate2),
    ]);
    final results = await reads;
    expect(results.first, isA<StateError>());
    expect(results.last, null);
    expect(store.values.containsKey(ClientEpochIdentity.identityKey), false);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
  });

  test('creates one stable UUID for simultaneous consumers', () async {
    final store = _MemoryEpochStorage();
    var calls = 0;
    final epochs = ClientEpochIdentity(store, newUuid: () {
      calls++;
      return oldId;
    });
    expect(await Future.wait(List.generate(16, (_) => epochs.current())),
        everyElement(oldId));
    expect(calls, 1);
    expect(store.values[ClientEpochIdentity.identityKey], oldId);
  });

  test('never rotates without authenticated terminal acknowledgement',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.rotateBeforeNewSession(), false);
    expect(await epochs.current(), oldId);
  });

  test('keeps epoch when a session, candidate or stop remains durable',
      () async {
    for (final blocker in [
      ClientEpochIdentity.sessionNonceKey,
      ClientEpochIdentity.candidateKey,
      ClientEpochIdentity.stopPendingKey,
    ]) {
      final store = _MemoryEpochStorage()
        ..values[ClientEpochIdentity.identityKey] = oldId
        ..values[blocker] = '1';
      final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
      await epochs.acknowledgeTerminal();
      expect(await epochs.rotateBeforeNewSession(), false,
          reason: 'must retain old epoch while $blocker exists');
      expect(await epochs.current(), oldId);
      expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
      store.values.remove(blocker);
      expect(await epochs.rotateBeforeNewSession(), true);
      expect(await epochs.current(), nextId);
      expect(store.values.containsKey(ClientEpochIdentity.rotationReadyKey),
          false);
      expect(await epochs.rotateBeforeNewSession(), false);
    }
  });

  test('restart retains terminal marker without a server mapping', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    await ClientEpochIdentity(store, newUuid: () => nextId)
        .acknowledgeTerminal();
    final afterRestart = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await afterRestart.rotateBeforeNewSession(), true);
    expect(await afterRestart.current(), nextId);
    expect(store.values.length, 1);
  });

  test('rejects corrupt persisted epoch without overwriting it', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = 'not-a-uuid';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await expectLater(epochs.current(), throwsA(isA<StateError>()));
    expect(store.values[ClientEpochIdentity.identityKey], 'not-a-uuid');
  });

  test('refuses to rotate to the same epoch UUID', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => oldId);
    await epochs.acknowledgeTerminal();
    await expectLater(
        epochs.rotateBeforeNewSession(), throwsA(isA<StateError>()));
    expect(await epochs.current(), oldId);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
  });

  test('atomic admission rotates and owns exactly one candidate', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.acknowledgeTerminal();
    final results = await Future.wait([
      epochs.beginCandidateReservation(candidate1),
      epochs.beginCandidateReservation(candidate2),
    ]);
    expect(results, [nextId, null]);
    expect(await epochs.current(), nextId);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
    expect(
        store.values.containsKey(ClientEpochIdentity.rotationReadyKey), false);
    expect(await epochs.rotateBeforeNewSession(), false);
  });

  test('claim without terminal marker retains identity and durably owns nonce',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.beginCandidateReservation(candidate1), oldId);
    expect(store.values[ClientEpochIdentity.identityKey], oldId);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
    final afterRestart = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await afterRestart.beginCandidateReservation(candidate2), null);
  });

  test('candidate cannot be claimed over possession or pending revoke',
      () async {
    for (final blocker in [
      ClientEpochIdentity.sessionNonceKey,
      ClientEpochIdentity.candidateKey,
      ClientEpochIdentity.stopPendingKey,
    ]) {
      final store = _MemoryEpochStorage()
        ..values[ClientEpochIdentity.identityKey] = oldId
        ..values[blocker] = '1';
      final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
      await epochs.acknowledgeTerminal();
      expect(await epochs.beginCandidateReservation(candidate1), null);
      expect(await epochs.current(), oldId);
      expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    }
  });

  test('corrupt durable nonce and candidate still block a new epoch', () async {
    for (final blocker in [
      ClientEpochIdentity.sessionNonceKey,
      ClientEpochIdentity.candidateKey,
    ]) {
      final store = _MemoryEpochStorage()
        ..values[ClientEpochIdentity.identityKey] = oldId
        ..values[blocker] = 'corrupt-capability';
      final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
      await epochs.acknowledgeTerminal();
      expect(await epochs.beginCandidateReservation(candidate1), null);
      final afterRestart = ClientEpochIdentity(store, newUuid: () => nextId);
      expect(await afterRestart.beginCandidateReservation(candidate2), null);
      expect(store.values[blocker], 'corrupt-capability');
      expect(await afterRestart.current(), oldId);
    }
  });

  test('stop intent and candidate claim share a serialization gate', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.acknowledgeTerminal();
    final pendingStop = epochs.synchronizedStorage(
        () => store.write(ClientEpochIdentity.stopPendingKey, '1'));
    final reservation = epochs.beginCandidateReservation(candidate1);
    await pendingStop;
    expect(await reservation, null);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
  });

  test('rejected candidate write never claims an untracked nonce', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.acknowledgeTerminal();
    store.rejectCandidateWrite = true;
    await expectLater(epochs.beginCandidateReservation(candidate1),
        throwsA(isA<StateError>()));
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
    store.rejectCandidateWrite = false;
    expect(await epochs.beginCandidateReservation(candidate2), nextId);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate2);
  });

  test('missing prior epoch with terminal marker fails without minting',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.rotationReadyKey] = '1';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await expectLater(epochs.beginCandidateReservation(candidate1),
        throwsA(isA<StateError>()));
    expect(store.values.containsKey(ClientEpochIdentity.identityKey), false);
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
  });

  test('atomic promotion consumes only the exact durable candidate', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await epochs.beginCandidateReservation(candidate1), oldId);
    expect(await epochs.promoteCandidate(candidate2), false);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
    expect(await epochs.promoteCandidate(candidate1), true);
    expect(store.values[ClientEpochIdentity.sessionNonceKey], candidate1);
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
    expect(await epochs.beginCandidateReservation(candidate2), null);
  });

  test('cancel and promotion compete without losing a live credential',
      () async {
    for (final cancelFirst in [true, false]) {
      final store = _MemoryEpochStorage()
        ..values[ClientEpochIdentity.identityKey] = oldId;
      final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
      await epochs.beginCandidateReservation(candidate1);
      final operations = cancelFirst
          ? [
              epochs.clearCandidateIfMatches(candidate1),
              epochs.promoteCandidate(candidate1)
            ]
          : [
              epochs.promoteCandidate(candidate1),
              epochs.clearCandidateIfMatches(candidate1)
            ];
      final outcomes = await Future.wait(operations);
      expect(outcomes, [true, false]);
      expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
      if (cancelFirst) {
        expect(store.values.containsKey(ClientEpochIdentity.sessionNonceKey),
            false);
      } else {
        expect(store.values[ClientEpochIdentity.sessionNonceKey], candidate1);
      }
    }
  });

  test('stale candidate cleanup cannot delete another reservation', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.beginCandidateReservation(candidate1);
    expect(await epochs.clearCandidateIfMatches(candidate2), false);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
    expect(await epochs.clearCandidateIfMatches(candidate1), true);
    await epochs.beginCandidateReservation(candidate2);
    expect(await epochs.clearCandidateIfMatches(candidate1), false);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate2);
  });

  test('a concurrent stop marker is never erased by promotion', () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.beginCandidateReservation(candidate1);
    await epochs.synchronizedStorage(
        () => store.write(ClientEpochIdentity.stopPendingKey, '1'));
    expect(await epochs.clearStopIntentIfNoOwnership(), false);
    expect(await epochs.promoteCandidate(candidate1), true);
    expect(await epochs.clearStopIntentIfNoOwnership(), false);
    expect(store.values[ClientEpochIdentity.stopPendingKey], '1');
    await epochs.synchronizedStorage(
        () => store.delete(ClientEpochIdentity.sessionNonceKey));
    expect(await epochs.clearStopIntentIfNoOwnership(), true);
    expect(store.values.containsKey(ClientEpochIdentity.stopPendingKey), false);
  });

  test(
      'promotion failure retains candidate and never replaces other possession',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.beginCandidateReservation(candidate1);
    store.rejectNonceWrite = true;
    await expectLater(
        epochs.promoteCandidate(candidate1), throwsA(isA<StateError>()));
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
    store.rejectNonceWrite = false;
    store.values[ClientEpochIdentity.sessionNonceKey] = candidate2;
    expect(await epochs.promoteCandidate(candidate1), false);
    expect(store.values[ClientEpochIdentity.sessionNonceKey], candidate2);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate1);
  });

  test('reservation write failure retains rotation proof and old epoch',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.acknowledgeTerminal();
    store.rejectIdentityWrite = true;
    await expectLater(epochs.beginCandidateReservation(candidate1),
        throwsA(isA<StateError>()));
    expect(store.values[ClientEpochIdentity.identityKey], oldId);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
    store.rejectIdentityWrite = false;
    final afterRestart = ClientEpochIdentity(store, newUuid: () => nextId);
    expect(await afterRestart.beginCandidateReservation(candidate2), nextId);
    expect(store.values[ClientEpochIdentity.identityKey], nextId);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate2);
  });

  test('marker deletion failure cannot expose retired epoch to new candidate',
      () async {
    const thirdId = 'f00df00d-aaaa-4000-8000-000000000001';
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    await ClientEpochIdentity(store, newUuid: () => nextId)
        .acknowledgeTerminal();
    store.rejectRotationDelete = true;
    await expectLater(
        ClientEpochIdentity(store, newUuid: () => nextId)
            .beginCandidateReservation(candidate1),
        throwsA(isA<StateError>()));
    expect(store.values[ClientEpochIdentity.identityKey], nextId);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
    store.rejectRotationDelete = false;
    final retry = ClientEpochIdentity(store, newUuid: () => thirdId);
    expect(await retry.beginCandidateReservation(candidate2), thirdId);
    expect(store.values[ClientEpochIdentity.identityKey], thirdId);
    expect(store.values[ClientEpochIdentity.candidateKey], candidate2);
    expect(await retry.beginCandidateReservation(candidate1), null);
  });

  test('malformed rotation marker blocks main admission and legacy rotation',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId
      ..values[ClientEpochIdentity.rotationReadyKey] = 'garbage';
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await expectLater(epochs.beginCandidateReservation(candidate1),
        throwsA(isA<StateError>()));
    await expectLater(
        epochs.rotateBeforeNewSession(), throwsA(isA<StateError>()));
    expect(store.values[ClientEpochIdentity.identityKey], oldId);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], 'garbage');
    expect(store.values.containsKey(ClientEpochIdentity.candidateKey), false);
  });

  test('failed secure write never creates repeated untracked rotations',
      () async {
    final store = _MemoryEpochStorage()
      ..values[ClientEpochIdentity.identityKey] = oldId;
    final epochs = ClientEpochIdentity(store, newUuid: () => nextId);
    await epochs.acknowledgeTerminal();
    store.rejectIdentityWrite = true;
    await expectLater(
        epochs.rotateBeforeNewSession(), throwsA(isA<StateError>()));
    store.rejectIdentityWrite = false;
    expect(await epochs.current(), oldId);
    expect(store.values[ClientEpochIdentity.rotationReadyKey], '1');
    expect(await epochs.rotateBeforeNewSession(), true);
    expect(await epochs.current(), nextId);
    expect(
        store.values.containsKey(ClientEpochIdentity.rotationReadyKey), false);
  });
}
