import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revoltvpn/logic/app_colors.dart';

class WebsiteButton extends StatelessWidget {
  const WebsiteButton({super.key});

  static Future<void> launchWebsite() async {
    final Uri url = Uri.parse('https://userevolt.app');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.language, color: AppColors.textWhite, size: 28),
      onPressed: launchWebsite,
      tooltip: 'Website',
      splashRadius: 24,
    );
  }
}
