import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

// ── lib/screens/settings/in_settings/rain.dart ──────────────────────────────
// Toggle for the animated rain overlay on the main screen.
//
// Same architecture as haptic.dart: exports a top-level bool read synchronously
// by lib/components/rain.dart. Default: true (rain is on — opt-out).

// lib/components/rain.dart reads this in its build method.
bool rainEnabled = true;

class RainToggleTile extends StatefulWidget {
  const RainToggleTile({super.key});

  @override
  State<RainToggleTile> createState() => _RainToggleTileState();
}

class _RainToggleTileState extends State<RainToggleTile> {
  bool _on = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('rain_effect_enabled') ?? true;
    rainEnabled = value;
    if (mounted) setState(() => _on = value);
  }

  Future<void> _toggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rain_effect_enabled', value);
    rainEnabled = value;
    setState(() => _on = value);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text(
        'Rain effect',
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
