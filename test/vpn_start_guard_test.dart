import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/vpn_start_guard.dart';

void main() {
  test('synchronous partial cleanup callback cannot start another cleanup',
      () async {
    final guard = VpnStartGuard();
    final nativeStop = Completer<void>();
    late Future<bool> nested;
    var nativeStops = 0;
    final first = guard.cleanupFailedStart(() {
      nativeStops++;
      expect(guard.cannotRestart, true);
      nested = guard.cleanupFailedStart(() {
        nativeStops++;
        return Future<void>.value();
      });
      return nativeStop.future;
    });
    expect(await nested, false);
    expect(nativeStops, 1);
    expect(guard.cannotRestart, true);
    nativeStop.complete();
    expect(await first, true);
    expect(guard.cannotRestart, false);
  });

  test('synchronous cleanup callback cannot reenter native start', () async {
    final guard = VpnStartGuard();
    late Future<bool> nestedStart;
    var nativeStarts = 0;
    final cleanup = guard.cleanupFailedStart(() {
      nestedStart = guard.start(() {
        nativeStarts++;
        return Future<void>.value();
      });
      return Future<void>.value();
    });
    expect(await nestedStart, false);
    expect(nativeStarts, 0);
    expect(await cleanup, true);
    expect(guard.cannotRestart, false);
  });

  test('duplicate deferred native stop cannot replace cleanup barrier',
      () async {
    final guard = VpnStartGuard();
    final nativeStart = Completer<void>();
    final nativeStop = Completer<void>();
    final starting = guard.start(() => nativeStart.future);
    guard.cancel();
    var primaryStops = 0;
    var duplicateStops = 0;
    guard.stopAfterLateStart(() {
      primaryStops++;
      return nativeStop.future;
    });
    guard.stopAfterLateStart(() {
      duplicateStops++;
      return Future<void>.value();
    });
    nativeStart.complete();
    expect(await starting, false);
    await Future<void>.delayed(Duration.zero);
    expect(primaryStops, 1);
    expect(duplicateStops, 0);
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
    nativeStop.complete();
    await Future<void>.delayed(Duration.zero);
    expect(guard.cannotRestart, false);
    guard.reset();
  });

  test('duplicate deferred cleanup cannot conceal first native stop failure',
      () async {
    final guard = VpnStartGuard();
    final nativeStart = Completer<void>();
    final starting = guard.start(() => nativeStart.future);
    guard.cancel();
    var primaryStops = 0;
    var duplicateStops = 0;
    guard.stopAfterLateStart(() {
      primaryStops++;
      throw StateError('native teardown failed');
    });
    guard.stopAfterLateStart(() {
      duplicateStops++;
      return Future<void>.value();
    });
    nativeStart.complete();
    expect(await starting, false);
    await Future<void>.delayed(Duration.zero);
    expect(primaryStops, 1);
    expect(duplicateStops, 0);
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
    expect(await guard.start(() async {}), false);
  });

  test('stop marker write fault still stops native tunnel after a late start',
      () async {
    final guard = VpnStartGuard();
    final starting = Completer<void>();
    final lateStop = Completer<void>();
    final start = guard.start(() => starting.future);
    guard.cancel();
    guard.blockUnsafeRestart();
    var stops = 0;
    guard.stopAfterLateStart(() {
      stops++;
      return lateStop.future;
    });
    expect(stops, 0);
    expect(guard.cannotRestart, true);
    starting.complete();
    expect(await start, false);
    await Future<void>.delayed(Duration.zero);
    expect(stops, 1);
    lateStop.complete();
    await Future<void>.delayed(Duration.zero);
    // Even if the deferred local stop succeeds, the missing durable marker
    // prevents new admissions until a secure process recovery.
    expect(guard.cannotRestart, true);
    expect(await guard.start(() async {}), false);
    expect(guard.reset, throwsStateError);
  });

  test('synchronous native callback cannot reenter a second start', () async {
    final guard = VpnStartGuard();
    final native = Completer<void>();
    late final Future<bool> nested;
    var invocations = 0;
    final first = guard.start(() {
      invocations++;
      expect(guard.isStarting, true);
      nested = guard.start(() {
        invocations++;
        return Future<void>.value();
      });
      return native.future;
    });
    expect(await nested, false);
    expect(invocations, 1);
    native.complete();
    expect(await first, true);
    expect(guard.isStarting, false);
  });

  test('synchronous cancellation during begin blocks an authenticated start',
      () async {
    final guard = VpnStartGuard();
    final first = guard.start(() {
      expect(guard.isStarting, true);
      guard.cancel();
      return Future<void>.value();
    });
    expect(await first, false);
    expect(guard.mayReportConnected, false);
    expect(guard.authorizeConnected, throwsStateError);
  });

  test('direct native start is denied during failed cleanup latch', () async {
    final guard = VpnStartGuard();
    guard.blockUnsafeRestart();
    var called = false;
    expect(
        await guard.start(() {
          called = true;
          return Future<void>.value();
        }),
        false);
    expect(called, false);
  });

  test('direct native start cannot bypass unfinished local cleanup', () async {
    final guard = VpnStartGuard();
    final pendingStop = Completer<void>();
    final cleanup = guard.cleanupFailedStart(() => pendingStop.future);
    var started = false;
    expect(
        await guard.start(() {
          started = true;
          return Future<void>.value();
        }),
        false);
    expect(started, false);
    pendingStop.complete();
    expect(await cleanup, true);
    expect(
        await guard.start(() {
          started = true;
          return Future<void>.value();
        }),
        true);
    expect(started, true);
  });

  test('synchronous begin exception releases reservation after propagation',
      () async {
    final guard = VpnStartGuard();
    final started = guard.start(() {
      expect(guard.isStarting, true);
      throw StateError('platform start failed synchronously');
    });
    await expectLater(started, throwsStateError);
    expect(guard.isStarting, false);
    expect(await guard.start(() async {}), true);
  });

  test('rejected native start stops partial VPN before retry', () async {
    final guard = VpnStartGuard();
    guard.reset();
    final rejectedStart = guard
        .start(() => Future<void>.error(StateError('partial TUN failure')));
    await expectLater(rejectedStart, throwsStateError);
    var stopCalls = 0;
    expect(
        await guard.cleanupFailedStart(() async {
          stopCalls++;
        }),
        true);
    expect(stopCalls, 1);
    expect(guard.cannotRestart, false);
    guard.reset();
    expect(await guard.start(() async {}), true);
  });

  test('failed partial-start cleanup locks down all future admissions',
      () async {
    final guard = VpnStartGuard();
    expect(
        await guard.cleanupFailedStart(
            () => Future<void>.error(StateError('native stop failed'))),
        false);
    expect(guard.cannotRestart, true);
    expect(guard.mayReportConnected, false);
    expect(guard.reset, throwsStateError);
    expect(await guard.cleanupFailedStart(() async {}), false);
  });

  test('partial-start cleanup holds restart barrier until native stop settles',
      () async {
    final guard = VpnStartGuard();
    final stop = Completer<void>();
    final clean = guard.cleanupFailedStart(() => stop.future);
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
    expect(await guard.cleanupFailedStart(() async {}), false);
    stop.complete();
    expect(await clean, true);
    expect(guard.cannotRestart, false);
  });

  test('synchronous native stop failure is also fail closed', () async {
    final guard = VpnStartGuard();
    expect(
        await guard.cleanupFailedStart(() {
          throw StateError('synchronous platform channel failure');
        }),
        false);
    expect(guard.cannotRestart, true);
    expect(guard.authorizeConnected, throwsStateError);
  });

  test('failed explicit native disconnect permanently denies reconnect',
      () async {
    final guard = VpnStartGuard();
    guard.reset();
    expect(await guard.start(() async {}), true);
    guard.authorizeConnected();
    expect(guard.mayReportConnected, true);
    guard.cancel();
    // Simulate stopVless throwing/timing out, even if server revoke succeeded.
    guard.blockUnsafeRestart();
    expect(guard.mayReportConnected, false);
    expect(guard.cannotRestart, true);
    expect(guard.reset, throwsStateError);
    expect(await guard.start(() async {}), false);
  });

  test('failed startup revocation stop cannot be reset by status callbacks',
      () async {
    final guard = VpnStartGuard();
    guard.blockUnsafeRestart();
    expect(guard.cannotRestart, true);
    expect(guard.authorizeConnected, throwsStateError);
    expect(guard.reset, throwsStateError);
    guard.cancel();
    expect(guard.cannotRestart, true);
    expect(guard.mayReportConnected, false);
  });

  test('native connected callbacks are denied without authenticated state',
      () async {
    final guard = VpnStartGuard();
    expect(guard.mayReportConnected, false);
    guard.reset();
    expect(guard.mayReportConnected, false);

    final startDone = Completer<void>();
    final start = guard.start(() => startDone.future);
    expect(guard.mayReportConnected, false);
    expect(guard.authorizeConnected, throwsStateError);
    startDone.complete();
    expect(await start, true);
    expect(guard.mayReportConnected, false);
    guard.authorizeConnected();
    expect(guard.mayReportConnected, true);
    guard.invalidateConnected();
    expect(guard.mayReportConnected, false);
  });

  test('cancelled or reset generations reject old connected callbacks',
      () async {
    final guard = VpnStartGuard();
    guard.authorizeConnected();
    expect(guard.mayReportConnected, true);
    guard.cancel();
    expect(guard.mayReportConnected, false);
    expect(guard.authorizeConnected, throwsStateError);
    guard.reset();
    expect(guard.mayReportConnected, false);
    guard.authorizeConnected();
    expect(guard.mayReportConnected, true);
  });

  test('failed startup restoration teardown permanently blocks reconnect',
      () async {
    final guard = VpnStartGuard();
    guard.blockUnsafeRestart();
    expect(guard.mayReportConnected, false);
    expect(guard.cannotRestart, true);
    expect(guard.authorizeConnected, throwsStateError);
    expect(guard.reset, throwsStateError);
  });

  test('late start cleanup never authorizes connected in a new attempt',
      () async {
    final guard = VpnStartGuard();
    final lateStart = Completer<void>();
    final lateStop = Completer<void>();
    final start = guard.start(() => lateStart.future);
    guard.cancel();
    expect(await guard.waitForStart(Duration.zero), false);
    guard.stopAfterLateStart(() => lateStop.future);
    expect(guard.mayReportConnected, false);
    lateStart.complete();
    expect(await start, false);
    await Future<void>.delayed(Duration.zero);
    expect(guard.authorizeConnected, throwsStateError);
    lateStop.complete();
    await Future<void>.delayed(Duration.zero);
    expect(guard.cannotRestart, false);
    guard.reset();
    expect(guard.mayReportConnected, false);
  });

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
