class SyncFailureWindow {
  final Duration limit;
  Duration? _firstFailureAt;

  SyncFailureWindow({required this.limit}) {
    if (limit <= Duration.zero) {
      throw ArgumentError.value(limit, 'limit', 'must be positive');
    }
  }

  bool get active => _firstFailureAt != null;

  void recordFailure(Duration now) {
    if (now.isNegative) {
      throw ArgumentError.value(now, 'now', 'must be non-negative');
    }
    _firstFailureAt ??= now;
  }

  bool isExpired(Duration now) {
    if (now.isNegative) {
      throw ArgumentError.value(now, 'now', 'must be non-negative');
    }
    final first = _firstFailureAt;
    if (first == null) return false;
    if (now < first) {
      throw StateError('Monotonic failure clock moved backwards.');
    }
    return now - first >= limit;
  }

  void reset() {
    _firstFailureAt = null;
  }
}
