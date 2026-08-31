import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';

class HapticFeedbackTile extends StatefulWidget {
  const HapticFeedbackTile({super.key});

  @override
  State<HapticFeedbackTile> createState() => _HapticFeedbackTileState();
}

class _HapticFeedbackTileState extends State<HapticFeedbackTile> {
  bool _on = HapticSettings.enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await HapticSettings.initialize();
    if (mounted) setState(() => _on = HapticSettings.enabled);
  }

  Future<void> _toggle(bool value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _on = value;
    });

    try {
      await HapticSettings.setEnabled(value);
    } catch (_) {
      if (mounted) setState(() => _on = HapticSettings.enabled);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text(
        'Haptic feedback',
        style: TextStyle(color: AppColors.textWhite, fontSize: 15),
      ),
      value: _on,
      onChanged: _saving ? null : _toggle,
      activeTrackColor: AppColors.accent.withAlpha(80),
      activeThumbColor: AppColors.accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }
}
