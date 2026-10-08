import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/client_epoch_identity.dart';

class _MemoryEpochStorage implements ClientEpochStorage {
  final values = <String, String>{};
  bool rejectIdentityWrite = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (rejectIdentityWrite && key == ClientEpochIdentity.identityKey) {
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
