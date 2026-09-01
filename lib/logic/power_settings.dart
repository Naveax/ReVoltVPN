import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android background-survival controls that ReVolt can actually verify.
abstract final class PowerSettings {
  PowerSettings._();

  static const MethodChannel _channel = MethodChannel(
    'com.revoltvpn.app/power',
  );

  static Future<bool> isBatteryOptimisationDisabled() async {
    if (kIsWeb) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestDisableBatteryOptimisation() async {
    if (kIsWeb) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the native runtime is alive according to the OS-facing bridge.
  /// This remains a coarse liveness signal until the native runtime exposes a
  /// ReVolt-specific health record.
  static Future<VpnRuntimeState> runtimeState() async {
    if (kIsWeb) {
      return const VpnRuntimeState(
        processAlive: false,
        vpnTransport: false,
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'isVpnRuntimeAlive',
      );
      return VpnRuntimeState(
        processAlive: result?['processAlive'] == true,
        vpnTransport: result?['vpnTransport'] == true,
      );
    } catch (_) {
      return const VpnRuntimeState(
        processAlive: false,
        vpnTransport: false,
      );
    }
  }
}

@immutable
class VpnRuntimeState {
  final bool processAlive;
  final bool vpnTransport;

  const VpnRuntimeState({
    required this.processAlive,
    required this.vpnTransport,
  });

  bool aliveFor({required bool tunMode}) =>
      processAlive && (!tunMode || vpnTransport);
}
