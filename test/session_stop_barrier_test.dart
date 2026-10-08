import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_stop_barrier.dart';

void main() {
  test('concurrent disconnect callers share one pending teardown', () async {
    final gate = SessionStopBarrier();
    final pending = Completer<void>();
    var stops = 0;
    final first = gate.run(() {
      stops++;
      return pending.future;
    });
    final second = gate.run(() {
      stops++;
      return Future<void>.value();
    });
    expect(identical(first, second), true);
    expect(stops, 1);
    expect(gate.isStopping, true);
    pending.complete();
    await Future.wait([first, second]);
    expect(gate.isStopping, false);
  });

  test('a failed teardown rejects all waiters and clears the barrier',
      () async {
    final gate = SessionStopBarrier();
    final pending = Completer<void>();
    final first = gate.run(() => pending.future);
    final second = gate.run(() async {});
    expect(identical(first, second), true);
    final firstExpect = expectLater(first, throwsStateError);
    final secondExpect = expectLater(second, throwsStateError);
    pending.completeError(StateError('revocation failed'));
    await Future.wait([firstExpect, secondExpect]);
    expect(gate.isStopping, false);
  });

  test('a synchronous native exception is an observable stop error', () async {
    final gate = SessionStopBarrier();
    final action = gate.run(() {
      throw StateError('native stop failed synchronously');
    });
    await expectLater(action, throwsStateError);
    expect(gate.isStopping, false);
  });

  test('a subsequent stop cannot overlap the previous pending future',
      () async {
    final gate = SessionStopBarrier();
    final firstStop = Completer<void>();
    var calls = 0;
    final first = gate.run(() {
      calls++;
      return firstStop.future;
    });
    final shared = gate.run(() {
      calls++;
      return Future<void>.value();
    });
    expect(calls, 1);
    firstStop.complete();
    await Future.wait([first, shared]);
    await gate.run(() {
      calls++;
      return Future<void>.value();
    });
    expect(calls, 2);
  });
}
