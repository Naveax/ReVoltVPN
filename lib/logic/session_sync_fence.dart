/// A status response is only valid for the session generation that sent it.
/// Invalidating the fence on stop/restart prevents an old HTTP response from
/// changing the next session's countdown, quota or watchdog state.
final class SessionSyncFence {
  int _generation = 0;
  int? _inFlightGeneration;

  int get current => _generation;

  bool accepts(int generation) => generation == _generation;

  /// One request per generation, but an old generation must never block a new
  /// session from polling just because its network Future has not settled.
  int? beginRequest() {
    if (_inFlightGeneration == _generation) return null;
    _inFlightGeneration = _generation;
    return _generation;
  }

  /// A late request must not release a newer generation's in-flight lock.
  void finishRequest(int generation) {
    if (_inFlightGeneration == generation) _inFlightGeneration = null;
  }

  void invalidate() {
    _generation++;
    _inFlightGeneration = null;
  }
}
