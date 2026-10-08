import 'dart:async';

/// Owns one background health/recovery poll at a time. Timer ticks that fire
/// before storage/network awaits settle join the same operation instead of
/// starting overlapping session candidate recovery or server revocation.
final class VpnHealthPollGate {
  Future<void>? _pending;
  int _generation = 0;

  bool get isPolling => _pending != null;
  int get generation => _generation;
  bool accepts(int capturedGeneration) => capturedGeneration == _generation;

  // Disconnect/next connect cancels the right to publish a previous poll's
  // result, even when its storage await completes after teardown is finished.
  void invalidate() => _generation++;

  Future<void> run(Future<void> Function() poll) {
    final existing = _pending;
    if (existing != null) return existing;

    // Reserve before running callbacks because fake health/storage providers
    // and synchronous native listeners can immediately reenter this gate.
    final completion = Completer<void>();
    final current = completion.future;
    _pending = current;
    Future<void>.sync(poll).then((_) {
      if (identical(_pending, current)) _pending = null;
      completion.complete();
    }, onError: (Object error, StackTrace stack) {
      if (identical(_pending, current)) _pending = null;
      completion.completeError(error, stack);
    });
    return current;
  }
}
