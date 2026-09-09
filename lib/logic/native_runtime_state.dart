class NativeRuntimeState {
  final bool active;
  final bool runtimeReady;
  final bool proxyOnly;
  final String runtimeToken;
  final String state;

  const NativeRuntimeState({
    required this.active,
    required this.runtimeReady,
    required this.proxyOnly,
    required this.runtimeToken,
    required this.state,
  });

  factory NativeRuntimeState.fromMap(Map<Object?, Object?> raw) {
    final active = raw['active'];
    final runtimeReady = raw['runtimeReady'];
    final proxyOnly = raw['proxyOnly'];
    final runtimeToken = raw['runtimeToken'];
    final state = raw['state'];

    if (active is! bool ||
        runtimeReady is! bool ||
        proxyOnly is! bool ||
        runtimeToken is! String ||
        state is! String) {
      throw const FormatException('Malformed native runtime state.');
    }
    if (active && runtimeToken.trim().isEmpty) {
      throw const FormatException(
        'Active native runtime is missing its generation token.',
      );
    }
    if (runtimeReady && !active) {
      throw const FormatException(
        'Inactive native runtime cannot report readiness.',
      );
    }

    return NativeRuntimeState(
      active: active,
      runtimeReady: runtimeReady,
      proxyOnly: proxyOnly,
      runtimeToken: runtimeToken,
      state: state,
    );
  }
}
