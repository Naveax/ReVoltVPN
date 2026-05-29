import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class InfoButton extends StatelessWidget {
  const InfoButton({Key? key}) : super(key: key);

  Future<void> _launchGitHub() async {
    final Uri url = Uri.parse('https://github.com/esefxdz/PaladinVPN');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.help_outline, color: Colors.white, size: 28),
      onPressed: _launchGitHub,
      tooltip: 'About PaladinVPN',
      splashRadius: 24,
    );
  }
}
