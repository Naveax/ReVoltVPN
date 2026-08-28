import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for the persisted haptic-feedback preference.
abstract final class HapticSettings {
  HapticSettings._();

  static const String _prefKey = 'haptic_feedback_enabled';

  static bool _enabled = false;
  static bool _initialized = false;

  static bool get enabled => _enabled;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? false;
    } catch (_) {
      // Haptics are optional. A storage failure must not block app startup.
      _enabled = false;
    } finally {
      _initialized = true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    _initialized = true;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
  }

  static Future<void> lightImpact() async {
    if (!_initialized) await initialize();
    if (_enabled) await HapticFeedback.lightImpact();
  }
}
