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

  bool get ownsGeneration => runtimeToken.trim().isNotEmpty;

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
        state is! String ||
        state.trim().isEmpty) {
      throw const FormatException('Malformed native runtime state.');
    }
    if (active && runtimeToken.trim().isEmpty) {
      throw const FormatException(
        'Active native runtime is missing its generation token.',
      );
    }
    if (runtimeReady && runtimeToken.trim().isEmpty) {
      throw const FormatException(
        'Ready native runtime is missing its generation token.',
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

bool nativeRuntimeAdoptionStillCurrent({
  required int capturedEpoch,
  required int currentEpoch,
  required bool disposed,
  required bool disconnecting,
}) {
  return !disposed && !disconnecting && capturedEpoch == currentEpoch;
}
