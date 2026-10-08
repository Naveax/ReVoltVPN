import 'package:flutter_test/flutter_test.dart';
import 'package:revoltvpn/logic/session_sync_fence.dart';

void main() {
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

  test('same-session concurrent requests retain the same generation', () {
    final fence = SessionSyncFence();
    final a = fence.current;
    final b = fence.current;
    expect(fence.accepts(a), true);
    expect(fence.accepts(b), true);
  });
}
