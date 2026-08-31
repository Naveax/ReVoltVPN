import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/settings/in_settings/connection_mode.dart';
import 'package:revoltvpn/screens/settings/in_settings/haptic.dart';
import 'package:revoltvpn/screens/settings/in_settings/lightning.dart';
import 'package:revoltvpn/screens/settings/in_settings/rain.dart';
import 'package:revoltvpn/screens/settings/in_settings/resilience.dart';

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
          ConnectionModeTile(),
          ResilienceModeTile(),
          HapticFeedbackTile(),
          RainToggleTile(),
          LightningToggleTile(),
        ],
      ),
    );
  }
}
