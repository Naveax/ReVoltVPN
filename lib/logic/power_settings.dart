import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android background-survival and system VPN policy controls.
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
  /// could be opened at all; a user declining still returns true.
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

  /// Opens Android's VPN settings where the user can enable Always-on VPN and
  /// "Block connections without VPN". Ordinary apps cannot silently enable
  /// lockdown; Android deliberately keeps this under user/admin control.
  static Future<bool> openVpnPolicySettings() async {
    if (kIsWeb) return false;
    try {
      return await _channel.invokeMethod<bool>('openVpnSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
