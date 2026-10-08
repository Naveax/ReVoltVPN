import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_sync_fence.dart';

void main() {
  test('old identity preflight cannot dispatch status for a new session',
      () async {
    final fence = SessionSyncFence();
    final identityRead = Completer<void>();
    final old = fence.beginRequest()!;
    var networkDispatches = 0;

    Future<void> pendingPoll() async {
      try {
        await identityRead.future;
        if (!fence.accepts(old)) return;
        networkDispatches++;
      } finally {
        fence.finishRequest(old);
      }
    }

    final obsolete = pendingPoll();
    fence.invalidate();
    final fresh = fence.beginRequest()!;
    identityRead.complete();
    await obsolete;
    expect(networkDispatches, 0);
    expect(fence.accepts(fresh), true);
    // The old completion must not unlock the new session's permit.
    expect(fence.beginRequest(), isNull);
    fence.finishRequest(fresh);
  });

  test('a status reply belongs to the generation which requested it', () {
    final fence = SessionSyncFence();
    final request = fence.current;
    expect(fence.accepts(request), true);
    fence.invalidate();
    expect(fence.accepts(request), false);
    expect(fence.accepts(fence.current), true);
  });

  test('an old reply is rejected after disconnect and subsequent start', () {
    final fence = SessionSyncFence();
    final oldRequest = fence.current;
    fence.invalidate(); // disconnect
    fence.invalidate(); // new session
    expect(fence.accepts(oldRequest), false);
    expect(fence.accepts(fence.current), true);
  });

  test('later reconnect cannot revive either previous request', () {
    final fence = SessionSyncFence();
    final first = fence.current;
    fence.invalidate();
    final second = fence.current;
    fence.invalidate();
    expect(fence.accepts(first), false);
    expect(fence.accepts(second), false);
    expect(fence.accepts(fence.current), true);
  });

  test('same session permits only one active status request', () {
    final fence = SessionSyncFence();
    final first = fence.beginRequest();
    expect(first, isNotNull);
    expect(fence.beginRequest(), isNull);
    fence.finishRequest(first!);
    expect(fence.beginRequest(), first);
  });

  test('new session can poll while old HTTP request remains unresolved', () {
    final fence = SessionSyncFence();
    final old = fence.beginRequest()!;
    fence.invalidate();
    final fresh = fence.beginRequest()!;
    expect(fresh, isNot(old));
    expect(fence.accepts(old), false);
    expect(fence.accepts(fresh), true);
    expect(fence.beginRequest(), isNull);
  });

  test('old HTTP completion never releases new session request slot', () {
    final fence = SessionSyncFence();
    final old = fence.beginRequest()!;
    fence.invalidate();
    final fresh = fence.beginRequest()!;
    fence.finishRequest(old);
    expect(fence.beginRequest(), isNull);
    fence.finishRequest(fresh);
    expect(fence.beginRequest(), fresh);
  });

  test('two invalidations retire every earlier HTTP generation', () {
    final fence = SessionSyncFence();
    final first = fence.beginRequest()!;
    fence.invalidate();
    final second = fence.beginRequest()!;
    fence.invalidate();
    final third = fence.beginRequest()!;
    fence.finishRequest(first);
    fence.finishRequest(second);
    expect(fence.beginRequest(), isNull);
    fence.finishRequest(third);
    expect(fence.beginRequest(), third);
  });

  test('same-session concurrent requests retain the same generation', () {
    final fence = SessionSyncFence();
    final a = fence.current;
    final b = fence.current;
    expect(fence.accepts(a), true);
    expect(fence.accepts(b), true);
  });
}
