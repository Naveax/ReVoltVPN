import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

// ── lib/screens/settings/in_settings/lightning.dart ─────────────────────────
// Toggle for the lightning strike overlay on the main screen.

final ValueNotifier<bool> lightningEnabled = ValueNotifier(true);

Future<void> loadLightningPref() async {
  final prefs = await SharedPreferences.getInstance();
  lightningEnabled.value = prefs.getBool('lightning_effect_enabled') ?? true;
}

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
    await loadLightningPref();
    if (mounted) setState(() => _on = lightningEnabled.value);
  }

  Future<void> _toggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lightning_effect_enabled', value);
    lightningEnabled.value = value;
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
