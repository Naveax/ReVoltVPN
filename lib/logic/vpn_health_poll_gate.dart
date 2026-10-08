import 'dart:async';

/// Owns one health/recovery poll per session epoch. Ticks within an epoch
/// share the same operation; a stale network/storage Future from a previous
/// epoch must never block a fresh session's first health check.
final class VpnHealthPollGate {
  Future<void>? _pending;
  int? _pendingGeneration;
  int _generation = 0;

  bool get isPolling => _pending != null && _pendingGeneration == _generation;
  int get generation => _generation;
  bool accepts(int capturedGeneration) => capturedGeneration == _generation;

  // Disconnect/next connect cancels the right to publish a previous poll's
  // result, even when its storage await completes after teardown is finished.
  void invalidate() => _generation++;

  Future<void> run(Future<void> Function() poll) {
    // The previous epoch may remain stuck in an I/O await. Do not join it.
    final existing = _pendingGeneration == _generation ? _pending : null;
    if (existing != null) return existing;

    // Reserve before running callbacks because fake health/storage providers
    // and synchronous native listeners can immediately reenter this gate.
    final completion = Completer<void>();
    final current = completion.future;
    _pending = current;
    _pendingGeneration = _generation;
    Future<void>.sync(poll).then((_) {
      if (identical(_pending, current)) {
        _pending = null;
        _pendingGeneration = null;
      }
      completion.complete();
    }, onError: (Object error, StackTrace stack) {
      if (identical(_pending, current)) {
        _pending = null;
        _pendingGeneration = null;
      }
      completion.completeError(error, stack);
    });
    return current;
  }
}
