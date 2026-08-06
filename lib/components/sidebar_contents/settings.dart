import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/settings/settings_screen.dart';

// ── lib/components/sidebar_contents/settings.dart ────────────────────────────
// Thin sidebar row — taps navigate to the full SettingsScreen.
// The actual settings UI lives in lib/screens/settings/ (separate folder,
// one file per feature).

class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  // Opens the settings page sliding in from the right — matches the
  // sidebar end-drawer animation so it feels like one continuous motion.
  static void open(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, __, ___) => const SettingsScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1.0, 0.0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            )),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.settings, color: AppColors.textWhite, size: 28),
      onPressed: () => open(context),
      tooltip: 'Settings',
      splashRadius: 24,
    );
  }
}
