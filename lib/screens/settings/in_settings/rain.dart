import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

// ── lib/screens/settings/in_settings/rain.dart ──────────────────────────────
// Toggle for the animated rain overlay on the main screen.

final ValueNotifier<bool> rainEnabled = ValueNotifier(true);

Future<void> loadRainPref() async {
  final prefs = await SharedPreferences.getInstance();
  rainEnabled.value = prefs.getBool('rain_effect_enabled') ?? true;
}

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
    await loadRainPref();
    if (mounted) setState(() => _on = rainEnabled.value);
  }

  Future<void> _toggle(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rain_effect_enabled', value);
    rainEnabled.value = value;
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
