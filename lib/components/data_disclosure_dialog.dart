// lib/components/data_disclosure_dialog.dart
// First-launch data disclosure dialog — Google Play Data safety section requirement.
// Shows once per install; preference persisted in SharedPreferences.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:revoltvpn/logic/app_colors.dart';

class DataDisclosureDialog {
  DataDisclosureDialog._();

  static const _key = 'data_disclosure_accepted';

  /// Shows the disclosure dialog if the user hasn't accepted it yet.
  /// Call once after the main screen is mounted (post-frame callback).
  static Future<void> showIfFirstLaunch(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_key) == true) return; // Already accepted.

    if (!context.mounted) return;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // Must tap Continue — no tap-outside dismiss.
      builder: (_) => const _DisclosureDialog(),
    );
    if (accepted != true) return;

    // Persist only after the user action is complete. If storage fails, do not
    // invent an accepted state; the disclosure will simply reappear later.
    try {
      final saved = await prefs.setBool(_key, true);
      if (!saved) {
        debugPrint('[Disclosure] Preference write was rejected');
      }
    } catch (e) {
      debugPrint('[Disclosure] Failed to persist acknowledgement: $e');
    }
  }
}

class _DisclosureDialog extends StatelessWidget {
  const _DisclosureDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.bgCard,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Before you connect',
              style: TextStyle(
                color: AppColors.textWhite,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'ReVoltVPN uses a randomly generated device ID plus session '
              'time and total data usage to issue and enforce server-defined '
              'session limits. The app does not use packet contents for quota '
              'accounting. Rewarded ads are disabled in this build; if a '
              'future build enables Google AdMob, Google may process ad and '
              'verification data, including pseudonymous verification data. '
              'See "Privacy Policy" in the sidebar for the full details.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.bgDeep,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
