import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/vpn_health_poll_gate.dart';

void main() {
  test('completed disconnect epoch invalidates delayed storage recovery',
      () async {
    final gate = VpnHealthPollGate();
    final storage = Completer<bool>();
    var recovered = 0;
    var published = 0;
    final pending = gate.run(() async {
      final captured = gate.generation;
      final stopMarker = await storage.future;
      if (!gate.accepts(captured)) return;
      if (stopMarker) recovered++;
      published++;
    });
    // The disconnect begins AND completes while the secure storage call is
    // still awaiting. A simple isStopping flag would already be false again.
    gate.invalidate();
    storage.complete(true);
    await pending;
    expect(recovered, 0);
    expect(published, 0);
    expect(gate.isPolling, false);
    await gate.run(() async {
      published++;
    });
    expect(published, 1);
  });

  test('next connect epoch ignores obsolete health recovery errors', () async {
    final gate = VpnHealthPollGate();
    final storage = Completer<void>();
    var lockedNewSession = false;
    final old = gate.run(() async {
      final captured = gate.generation;
      try {
        await storage.future;
      } catch (_) {
        if (gate.accepts(captured)) lockedNewSession = true;
      }
    });
    gate.invalidate(); // Accepted fresh connect.
    storage.completeError(StateError('obsolete secure-store read'));
    await old;
    expect(lockedNewSession, false);
    expect(gate.isPolling, false);
    expect(gate.accepts(gate.generation), true);
  });

  test('timer reentry and overlapping ticks share one recovery operation',
      () async {
    final gate = VpnHealthPollGate();
    final blocked = Completer<void>();
    late Future<void> nested;
    var healthCalls = 0;

    final first = gate.run(() {
      healthCalls++;
      expect(gate.isPolling, true);
      nested = gate.run(() {
        healthCalls++;
        return Future<void>.value();
      });
      return blocked.future;
    });

    expect(identical(first, nested), true);
    final second = gate.run(() {
      healthCalls++;
      return Future<void>.value();
    });
    expect(identical(first, second), true);
    expect(healthCalls, 1);
    blocked.complete();
    await first;
    await second;
    expect(gate.isPolling, false);
    await gate.run(() async {
      healthCalls++;
    });
    expect(healthCalls, 2);
  });

  test('pending recovery error reaches every waiter then releases the gate',
      () async {
    final gate = VpnHealthPollGate();
    final failure = Completer<void>();
    var calls = 0;
    final first = gate.run(() {
      calls++;
      return failure.future;
    });
    final second = gate.run(() {
      calls++;
      return Future<void>.value();
    });
    expect(identical(first, second), true);
    final firstFailed = expectLater(first, throwsStateError);
    final secondFailed = expectLater(second, throwsStateError);
    failure.completeError(StateError('storage unavailable'));
    await firstFailed;
    await secondFailed;
    expect(calls, 1);
    expect(gate.isPolling, false);
    await gate.run(() async {
      calls++;
    });
    expect(calls, 2);
  });
}
