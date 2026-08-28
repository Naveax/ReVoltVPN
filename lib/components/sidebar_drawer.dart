import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/components/sidebar_contents/gdpr_button.dart';
import 'package:revoltvpn/components/sidebar_contents/privacy_policy_button.dart';
import 'package:revoltvpn/components/sidebar_contents/info_button.dart';
import 'package:revoltvpn/components/sidebar_contents/discord_link_button.dart';
import 'package:revoltvpn/components/sidebar_contents/website_button.dart';
import 'package:revoltvpn/components/sidebar_contents/settings.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';
import 'package:revoltvpn/logic/updater.dart';

class SidebarDrawer extends StatefulWidget {
  const SidebarDrawer({super.key});

  @override
  State<SidebarDrawer> createState() => _SidebarDrawerState();
}

class _SidebarDrawerState extends State<SidebarDrawer> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      debugPrint('[Sidebar] PackageInfo version: ${info.version} '
          '(build: ${info.buildNumber})');
      if (mounted) setState(() => _version = info.version);
    } catch (e) {
      debugPrint('[Sidebar] PackageInfo failed: $e');
      if (mounted) setState(() => _version = '?.?.?');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.bgSurface,
      width: 280,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.slate15, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Image.asset('assets/brand.png', width: 36, height: 36,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.shield, size: 36, color: AppColors.accent),
                  ),
                  const SizedBox(width: 12),
                  const Text('ReVolt', style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800,
                    letterSpacing: 4, color: AppColors.textWhite,
                  )),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textDim, size: 22),
                    onPressed: () {
                      HapticSettings.tap();
                      Navigator.of(context).pop();
                    },
                    splashRadius: 20, padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            _Row(
              icon: Icons.admin_panel_settings_outlined,
              label: 'Ad Consent',
              onTap: () {
                Navigator.of(context).pop();
                GdprButton.showConsentForm();
              },
            ),

            _Row(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy Policy',
              onTap: () {
                Navigator.of(context).pop();
                PrivacyPolicyButton.launchPrivacyPolicy();
              },
            ),

            _Row(
              icon: Icons.help_outline,
              label: 'About',
              onTap: () {
                Navigator.of(context).pop();
                InfoButton.launchGitHub();
              },
            ),

            _Row(
              icon: Icons.discord,
              label: 'Discord',
              onTap: () {
                Navigator.of(context).pop();
                DiscordLinkButton.launchDiscord();
              },
            ),

            _Row(
              icon: Icons.language,
              label: 'Website',
              onTap: () {
                Navigator.of(context).pop();
                WebsiteButton.launchWebsite();
              },
            ),

            _Row(
              icon: Icons.settings,
              label: 'Settings',
              onTap: () {
                final drawerNavigator = Navigator.of(context);
                final rootNavigator = Navigator.of(context, rootNavigator: true);
                drawerNavigator.pop();
                SettingsButton.openWithNavigator(rootNavigator);
              },
            ),

            _Row(
              icon: Icons.system_update_alt,
              label: 'Check for updates',
              onTap: () {
                final drawerNavigator = Navigator.of(context);
                final rootNavigator = Navigator.of(context, rootNavigator: true);
                final messenger = ScaffoldMessenger.of(context);
                drawerNavigator.pop();
                Updater.checkWithHandles(
                  navigator: rootNavigator,
                  messenger: messenger,
                );
              },
            ),

            const Spacer(),

            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('ReVoltVPN · v$_version', textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.slate, fontSize: 11, letterSpacing: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Row({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticSettings.tap();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.textWhite, size: 28),
            const SizedBox(width: 16),
            Text(label, style: const TextStyle(
              color: AppColors.textWhite, fontSize: 15, fontWeight: FontWeight.w500,
            )),
          ],
        ),
      ),
    );
  }
}
