import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revoltvpn/logic/app_colors.dart';

class InfoButton extends StatelessWidget {
  const InfoButton({super.key});

  static Future<void> launchGitHub() async {
    final Uri url = Uri.parse('https://github.com/esefxdz/ReVoltVPN');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.help_outline, color: AppColors.textWhite, size: 28),
      onPressed: launchGitHub,
      tooltip: 'About ReVoltVPN',
      splashRadius: 24,
    );
  }
}
