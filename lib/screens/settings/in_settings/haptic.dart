import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

// A plain bool, not a ValueNotifier: this is only read at the moment of a tap,
// so nothing has to react to it changing. Default: false.
bool hapticEnabled = false;

/// Hydrates [hapticEnabled] from disk. Called at boot — the toggle tile below
/// only mounts once Settings is opened.
Future<void> loadHapticPref() async {
  final prefs = await SharedPreferences.getInstance();
  hapticEnabled = prefs.getBool('haptic_feedback_enabled') ?? false;
}

/// Haptic calls are deliberately best-effort: a vibration failure must never
/// block or fail a VPN connect/disconnect. `mediumImpact` is used instead of
/// `lightImpact` — the latter is imperceptible on many Android devices.
class Haptics {
  Haptics._();

  static Future<void> connectionChanged() async {
    if (!hapticEnabled) return;
    try {
      await HapticFeedback.mediumImpact();
    } catch (e) {
      debugPrint('[Haptics] Feedback unavailable: $e');
    }
  }

  static Future<void> previewEnabled() async {
    try {
      await HapticFeedback.selectionClick();
    } catch (e) {
      debugPrint('[Haptics] Preview unavailable: $e');
    }
  }
}

class HapticFeedbackTile extends StatefulWidget {
  const HapticFeedbackTile({super.key});

  @override
  State<HapticFeedbackTile> createState() => _HapticFeedbackTileState();
}

class _HapticFeedbackTileState extends State<HapticFeedbackTile> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await loadHapticPref();
    if (mounted) setState(() => _on = hapticEnabled);
  }

  // Writes to SharedPreferences AND updates the live bool so the connect
  // button sees the change immediately — no restart needed.
  Future<void> _toggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('haptic_feedback_enabled', value);
    hapticEnabled = value;
    if (value) unawaited(Haptics.previewEnabled());
    setState(() => _on = value);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text(
        'Haptic feedback',
        style: TextStyle(color: AppColors.textWhite, fontSize: 15),
      ),
      value: _on,
      onChanged: _toggle,
      activeTrackColor: AppColors.accent.withAlpha(80),
      activeThumbColor: AppColors.accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }
}
