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

    await showDialog(
      context: context,
      barrierDismissible: false, // Must tap Continue — no tap-outside dismiss.
      builder: (_) => _DisclosureDialog(
        onContinue: () {
          prefs.setBool(_key, true);
          Navigator.of(context).pop(); // Dismiss the dialog.
        },
      ),
    );
  }
}

class _DisclosureDialog extends StatelessWidget {
  final VoidCallback onContinue;

  const _DisclosureDialog({required this.onContinue});

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
            // Title
            const Text(
              'Before you connect',
              style: TextStyle(
                color: AppColors.textWhite,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),

            // Body
            const Text(
              'Revolt VPN creates a secure VPN tunnel to protect your '
              'traffic. To enforce your data/time quota, we log your '
              'connection duration and data usage, linked to your '
              'account. We do not log or monitor the content of your '
              'traffic. We do not share your data with third parties.'
              'If you have more questions, visit our website.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),

            // Continue button — full-width, accent
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onContinue,
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
