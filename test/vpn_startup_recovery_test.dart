import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/vpn_startup_recovery.dart';

void main() {
  test('startup verification failure latches before any secure storage await',
      () async {
    final store = Completer<void>();
    final calls = <String>[];
    final future = VpnStartupRecovery.quarantine(
      denyRestart: () => calls.add('latch'),
      persistStopIntent: () {
        calls.add('persist');
        return store.future;
      },
      stopNative: () async => calls.add('native'),
      revokeRemote: () async {
        calls.add('revoke');
        return true;
      },
    );
    expect(calls, ['latch', 'persist']);
    store.complete();
    final result = await future;
    expect(calls, ['latch', 'persist', 'native', 'revoke']);
    expect(result.completelyVerified, true);
  });

  test('missing durable marker still executes local and remote shutdown',
      () async {
    final calls = <String>[];
    final result = await VpnStartupRecovery.quarantine(
      denyRestart: () => calls.add('latch'),
      persistStopIntent: () {
        calls.add('persist');
        throw StateError('secure storage refused the write');
      },
      stopNative: () async => calls.add('native'),
      revokeRemote: () async {
        calls.add('revoke');
        return true;
      },
    );
    expect(calls, ['latch', 'persist', 'native', 'revoke']);
    expect(result.stopIntentPersisted, false);
    expect(result.nativeStopVerified, true);
    expect(result.remoteRevocationVerified, true);
    expect(result.completelyVerified, false);
  });

  test('native stop rejection does not skip credential revocation', () async {
    final calls = <String>[];
    final result = await VpnStartupRecovery.quarantine(
      denyRestart: () => calls.add('latch'),
      persistStopIntent: () async => calls.add('persist'),
      stopNative: () {
        calls.add('native');
        throw StateError('native service unavailable');
      },
      revokeRemote: () async {
        calls.add('revoke');
        return true;
      },
    );
    expect(calls, ['latch', 'persist', 'native', 'revoke']);
    expect(result.nativeStopVerified, false);
    expect(result.remoteRevocationVerified, true);
    expect(result.completelyVerified, false);
  });

  test('server revocation failure stays unverified after successful OS stop',
      () async {
    final calls = <String>[];
    final result = await VpnStartupRecovery.quarantine(
      denyRestart: () => calls.add('latch'),
      persistStopIntent: () async => calls.add('persist'),
      stopNative: () async => calls.add('native'),
      revokeRemote: () {
        calls.add('revoke');
        throw StateError('server unavailable');
      },
    );
    expect(calls, ['latch', 'persist', 'native', 'revoke']);
    expect(result.stopIntentPersisted, true);
    expect(result.nativeStopVerified, true);
    expect(result.remoteRevocationVerified, false);
    expect(result.completelyVerified, false);
  });

  test('pending remote revocation cannot be treated as terminal proof',
      () async {
    final result = await VpnStartupRecovery.quarantine(
      denyRestart: () {},
      persistStopIntent: () async {},
      stopNative: () async {},
      revokeRemote: () async => false,
    );
    expect(result.completelyVerified, false);
    expect(result.remoteRevocationVerified, false);
  });
}
