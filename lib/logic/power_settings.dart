import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Background-survival controls.
///
/// Android stops background services of apps that are not exempt from Doze and
/// App Standby, and it tears down the whole process group when a task is swiped
/// away. Those are OS behaviours, not app bugs, and the OS provides exactly two
/// sanctioned ways around them: a battery-optimisation exemption, and the
/// system's own Always-on VPN. Both need one user tap; neither can be forced.
abstract final class PowerSettings {
  PowerSettings._();

  static const MethodChannel _channel = MethodChannel(
    'com.revoltvpn.app/power',
  );

  /// Whether the OS has exempted this app from Doze / App Standby.
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

  /// Shows the system exemption dialog. Returns false only when no system UI
  /// could be opened at all — a user declining still returns true.
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

  /// Opens the OS VPN settings screen, where Always-on VPN is configured.
  static Future<bool> openVpnSettings() async {
    if (kIsWeb) return false;
    try {
      return await _channel.invokeMethod<bool>('openVpnSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the VPN runtime is genuinely alive.
  ///
  /// The Xray service runs in a separate process, so nothing it stores in
  /// statics is visible to us. This asks the OS instead: is our service process
  /// running, and (for TUN) is there an active VPN transport?
  static Future<VpnRuntimeState> runtimeState() async {
    if (kIsWeb) return const VpnRuntimeState(processAlive: false, vpnTransport: false);
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'isVpnRuntimeAlive',
      );
      return VpnRuntimeState(
        processAlive: result?['processAlive'] == true,
        vpnTransport: result?['vpnTransport'] == true,
      );
    } catch (_) {
      return const VpnRuntimeState(processAlive: false, vpnTransport: false);
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

  /// TUN needs both a live service and a real VPN interface. Proxy mode has no
  /// VPN interface at all, so the service process is the whole signal.
  bool aliveFor({required bool tunMode}) =>
      processAlive && (!tunMode || vpnTransport);
}
