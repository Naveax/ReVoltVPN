import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revoltvpn/logic/app_colors.dart';

class DiscordLinkButton extends StatelessWidget {
  const DiscordLinkButton({super.key});

  static Future<void> launchDiscord() async {
    final Uri url = Uri.parse('https://discord.gg/y7SXpjr2ff');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.discord, color: AppColors.textWhite, size: 28),
      onPressed: launchDiscord,
      tooltip: 'Join Discord',
      splashRadius: 24,
    );
  }
}
