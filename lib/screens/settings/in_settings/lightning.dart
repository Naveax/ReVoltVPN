import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

// ── lib/screens/settings/in_settings/lightning.dart ─────────────────────────
// Toggle for the lightning strike overlay on the main screen.
//
// Same architecture as haptic.dart: exports a top-level bool read synchronously
// by lib/components/lightning.dart. Default: true (lightning is on — opt-out).

// lib/components/lightning.dart reads this in its build method.
bool lightningEnabled = true;

class LightningToggleTile extends StatefulWidget {
  const LightningToggleTile({super.key});

  @override
  State<LightningToggleTile> createState() => _LightningToggleTileState();
}

class _LightningToggleTileState extends State<LightningToggleTile> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('lightning_effect_enabled') ?? true;
    lightningEnabled = value;
    if (mounted) setState(() => _on = value);
  }

  Future<void> _toggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lightning_effect_enabled', value);
    lightningEnabled = value;
    setState(() => _on = value);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text(
        'Lightning effect',
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
