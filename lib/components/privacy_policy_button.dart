import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PrivacyPolicyButton extends StatelessWidget {
  const PrivacyPolicyButton({super.key});

  Future<void> _launchPrivacyPolicy() async {
    final Uri url = Uri.parse('https://github.com/esefxdz/ReVoltVPN/blob/main/PRIVACY_POLICY.md');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.privacy_tip_outlined, color: Colors.white, size: 28),
      onPressed: _launchPrivacyPolicy,
      tooltip: 'Privacy Policy',
      splashRadius: 24,
    );
  }
}
