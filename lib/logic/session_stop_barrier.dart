import 'dart:async';

/// Serializes teardown for one SessionTimer. Concurrent callers observe the
/// same completion/error; a later start cannot mistake an in-flight revoke
/// for an already-finished stop.
final class SessionStopBarrier {
  Future<void>? _pending;

  bool get isStopping => _pending != null;

  Future<void> run(Future<void> Function() stop) {
    final existing = _pending;
    if (existing != null) return existing;

    // Publish ownership BEFORE invoking the supplied action. The action may
    // synchronously notify listeners which reenter disconnect on this stack.
    final completer = Completer<void>();
    final future = completer.future;
    _pending = future;
    Future<void>.sync(stop).then((_) {
      if (identical(_pending, future)) _pending = null;
      completer.complete();
    }, onError: (Object error, StackTrace stack) {
      if (identical(_pending, future)) _pending = null;
      completer.completeError(error, stack);
    });
    return future;
  }
}
