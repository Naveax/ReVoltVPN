import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/client_epoch_identity.dart';

class _MemoryEpochStorage implements ClientEpochStorage {
  final values = <String, String>{};
  bool rejectIdentityWrite = false;
  bool rejectCandidateWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if ((rejectIdentityWrite && key == ClientEpochIdentity.identityKey) ||
        (rejectCandidateWrite && key == ClientEpochIdentity.candidateKey)) {
      throw StateError('simulated secure storage failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  const oldId = '12345678-1234-4234-8234-123456789abc';
  const nextId = 'deadbeef-abcd-4000-8000-123456789abc';

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

  const candidate1 = '11111111111111111111111111111111';
  const candidate2 = '22222222222222222222222222222222';

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
    expect(await epochs.rotateBeforeNewSession(), false);
    expect(
        store.values.containsKey(ClientEpochIdentity.rotationReadyKey), false);
  });
}
