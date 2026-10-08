import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/vpn_start_guard.dart';

void main() {
  test('cancel before native start prevents any engine invocation', () async {
    final guard = VpnStartGuard();
    guard.cancel();
    var calls = 0;
    expect(
        await guard.start(() {
          calls++;
          return Future<void>.value();
        }),
        false);
    expect(calls, 0);
    guard.reset();
    expect(
        await guard.start(() async {
          calls++;
        }),
        true);
    expect(calls, 1);
  });

  test('cancel during native start cannot report connected', () async {
    final guard = VpnStartGuard();
    final completing = Completer<void>();
    final started = guard.start(() => completing.future);
    expect(guard.isStarting, true);
    guard.cancel();
    final settling = guard.waitForStart(const Duration(seconds: 1));
    completing.complete();
    expect(await settling, true);
    expect(await started, false);
    expect(guard.isStarting, false);
  });

  test('two native starts cannot overlap', () async {
    final guard = VpnStartGuard();
    final completing = Completer<void>();
    final first = guard.start(() => completing.future);
    var otherStarted = false;
    expect(
        await guard.start(() async {
          otherStarted = true;
        }),
        false);
    expect(otherStarted, false);
    completing.complete();
    expect(await first, true);
  });

  test('timed out native start stays blocked through deferred cleanup',
      () async {
    final guard = VpnStartGuard();
    final completing = Completer<void>();
    final lateStop = Completer<void>();
    final started = guard.start(() => completing.future);
    guard.cancel();
    expect(await guard.waitForStart(Duration.zero), false);
    var stopped = 0;
    guard.stopAfterLateStart(() {
      stopped++;
      return lateStop.future;
    });
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
    completing.complete();
    expect(await started, false);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, 1);
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
    lateStop.complete();
    await Future<void>.delayed(Duration.zero);
    expect(guard.cannotRestart, false);
    guard.reset();
    expect(await guard.start(() async {}), true);
  });

  test('failed deferred native stop denies reconnection', () async {
    final guard = VpnStartGuard();
    final completing = Completer<void>();
    final started = guard.start(() => completing.future);
    guard.cancel();
    expect(await guard.waitForStart(Duration.zero), false);
    guard.stopAfterLateStart(() async {
      throw StateError('simulated failed late stop');
    });
    completing.complete();
    expect(await started, false);
    await Future<void>.delayed(Duration.zero);
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
  });

  test('native start rejection still allows defensive stop', () async {
    final guard = VpnStartGuard();
    final completing = Completer<void>();
    final started = guard.start(() => completing.future);
    guard.cancel();
    final settling = guard.waitForStart(const Duration(seconds: 1));
    final rejected = expectLater(started, throwsStateError);
    completing.completeError(StateError('native rejected start'));
    expect(await settling, true);
    await rejected;
    expect(guard.isStarting, false);
  });
}
