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

    final operation = Future<void>.sync(stop);
    late final Future<void> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_pending, tracked)) _pending = null;
    });
    _pending = tracked;
    return tracked;
  }
}
