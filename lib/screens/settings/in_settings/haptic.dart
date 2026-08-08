import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

bool hapticEnabled = false;

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

  // Loads persisted state and syncs the top-level bool.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('haptic_feedback_enabled') ?? false;
    hapticEnabled = value;
    if (mounted) setState(() => _on = value);
  }

  // Writes to SharedPreferences AND updates the live bool so the connect
  // button sees the change immediately — no restart needed.
  Future<void> _toggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('haptic_feedback_enabled', value);
    hapticEnabled = value;
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
