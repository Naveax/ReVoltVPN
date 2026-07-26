import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/components/sidebar_contents/gdpr_button.dart';
import 'package:revoltvpn/components/sidebar_contents/privacy_policy_button.dart';
import 'package:revoltvpn/components/sidebar_contents/info_button.dart';
import 'package:revoltvpn/components/sidebar_contents/discord_link_button.dart';

/// Right-edge drawer. Four fully-tappable rows — tap anywhere on a row
/// to trigger its action and close the drawer.
class SidebarDrawer extends StatelessWidget {
  const SidebarDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.bgSurface,
      width: 280,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──────────────────────────────────────────────────
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
                    onPressed: () => Navigator.of(context).pop(),
                    splashRadius: 20, padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── Ad Consent (fully tappable) ─────────────────────────────
            _Row(
              icon: Icons.admin_panel_settings_outlined,
              label: 'Ad Consent',
              onTap: () {
                Navigator.of(context).pop();
                GdprButton.showConsentForm();
              },
            ),

            // ── Privacy Policy (fully tappable) ─────────────────────────
            _Row(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy Policy',
              onTap: () {
                Navigator.of(context).pop();
                PrivacyPolicyButton.launchPrivacyPolicy();
              },
            ),

            // ── About (fully tappable) ──────────────────────────────────
            _Row(
              icon: Icons.help_outline,
              label: 'About',
              onTap: () {
                Navigator.of(context).pop();
                InfoButton.launchGitHub();
              },
            ),

            // ── Discord (fully tappable) ────────────────────────────────
            _Row(
              icon: Icons.discord,
              label: 'Discord',
              onTap: () {
                Navigator.of(context).pop();
                DiscordLinkButton.launchDiscord();
              },
            ),

            const Spacer(),

            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('ReVoltVPN · v1.0.6', textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.slate, fontSize: 11, letterSpacing: 1),
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
      onTap: onTap,
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
