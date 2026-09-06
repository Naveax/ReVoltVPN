import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Background-survival controls.
///
/// Android stops background services of apps that are not exempt from Doze and
/// App Standby, and it tears down the whole process group when a task is swiped
/// away. Those are OS behaviours, not app bugs; the battery-optimisation
/// exemption is the one sanctioned way an app can ask for around them, and it
/// still needs one user tap.
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
}
