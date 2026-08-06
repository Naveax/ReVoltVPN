import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/settings/in_settings/haptic.dart';
import 'package:revoltvpn/screens/settings/in_settings/rain.dart';
import 'package:revoltvpn/screens/settings/in_settings/lightning.dart';

// ── lib/screens/settings/settings_screen.dart ────────────────────────────────
// Settings shell — full-screen page reached from the sidebar.
//
// Folder layout:
//   lib/screens/settings/       ← this folder: settings family
//     settings_screen.dart      ← shell: Scaffold + AppBar + ListView (this file)
//     *_tile.dart               ← one file per setting feature (add below)
//   lib/components/sidebar_contents/
//     settings.dart             ← thin sidebar row that navigates here
//
// To add a setting:
//   1. Create a new file in this folder, e.g. appearance_tile.dart
//   2. Import it below
//   3. Append it to the children list

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textWhite),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(
            color: AppColors.textWhite,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          HapticFeedbackTile(),
          RainToggleTile(),
          LightningToggleTile(),
          // ── Add setting tiles here ────────────────────────────────────────
          // Each tile imports from its own file in this folder.
        ],
      ),
    );
  }
}
