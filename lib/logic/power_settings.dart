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
}
