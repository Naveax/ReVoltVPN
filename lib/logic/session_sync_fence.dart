/// A status response is only valid for the session generation that sent it.
/// Invalidating the fence on stop/restart prevents an old HTTP response from
/// changing the next session's countdown, quota or watchdog state.
final class SessionSyncFence {
  int _generation = 0;

  int get current => _generation;

  bool accepts(int generation) => generation == _generation;

  void invalidate() => _generation++;
}
