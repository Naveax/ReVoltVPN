import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum HapticKind { tap, selection, success }

/// App-wide haptic controller.
///
/// The preference is loaded before the UI starts. On Android we use a native
/// vibrator channel first so feedback does not depend on a settings screen
/// having been opened or on Material widgets choosing to emit feedback.
/// Flutter's HapticFeedback remains the cross-platform fallback.
abstract final class HapticSettings {
  HapticSettings._();

  static const String _prefKey = 'haptic_feedback_enabled';
  static const MethodChannel _channel =
      MethodChannel('com.revoltvpn.app/haptics');

  static bool _enabled = false;
  static bool _initialized = false;

  static bool get enabled => _enabled;

  static Future<void> initialize() async {
    if (_initialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? false;
    } catch (e) {
      debugPrint('[Haptics] Failed to load preference: $e');
      _enabled = false;
    } finally {
      _initialized = true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    final previous = _enabled;
    _enabled = value;
    _initialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setBool(_prefKey, value);
      if (!saved) throw StateError('SharedPreferences rejected haptic setting');
    } catch (e) {
      _enabled = previous;
      debugPrint('[Haptics] Failed to persist preference: $e');
      rethrow;
    }
  }

  static void tap() => unawaited(_impact(HapticKind.tap));

  static void selection() => unawaited(_impact(HapticKind.selection));

  static void success() => unawaited(_impact(HapticKind.success));

  static Future<void> _impact(HapticKind kind) async {
    if (!_initialized) await initialize();
    if (!_enabled || kIsWeb) return;

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final handled = await _channel.invokeMethod<bool>(
              'impact',
              <String, Object>{'kind': kind.name},
            ) ??
            false;
        if (handled) return;
      } catch (e) {
        debugPrint('[Haptics] Native impact unavailable: $e');
      }
    }

    switch (kind) {
      case HapticKind.tap:
        await HapticFeedback.lightImpact();
        break;
      case HapticKind.selection:
        await HapticFeedback.selectionClick();
        break;
      case HapticKind.success:
        await HapticFeedback.mediumImpact();
        break;
    }
  }
}
