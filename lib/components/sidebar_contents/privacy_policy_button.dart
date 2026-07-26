import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revoltvpn/logic/app_colors.dart';

class PrivacyPolicyButton extends StatelessWidget {
  const PrivacyPolicyButton({super.key});

  /// Public entry point for the sidebar or any other widget.
  static Future<void> launchPrivacyPolicy() async {
    final Uri url = Uri.parse('https://github.com/esefxdz/ReVoltVPN/blob/main/PRIVACY_POLICY.md');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.privacy_tip_outlined, color: AppColors.textWhite, size: 28),
      onPressed: launchPrivacyPolicy,
      tooltip: 'Privacy Policy',
      splashRadius: 24,
    );
  }
}
