import 'dart:async';

/// A tiny FIFO async gate for stateful resources that must not observe
/// overlapping read/write/delete operations.
class SerializedOperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final previous = _tail;
    final completer = Completer<T>();

    _tail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed operation reports its error through its own completer. The
        // queue itself must stay usable for later cleanup attempts.
      }

      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();

    return completer.future;
  }
}
