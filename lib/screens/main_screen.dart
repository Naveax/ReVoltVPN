import 'package:flutter/material.dart';
import 'package:revoltvpn/components/header.dart';
import 'package:revoltvpn/components/status_text.dart';
import 'package:revoltvpn/components/connect_button.dart';
import 'package:revoltvpn/components/bottom_bar.dart';
import 'package:revoltvpn/components/info_button.dart';
import 'package:revoltvpn/components/privacy_policy_button.dart';
import 'package:revoltvpn/components/gdpr_button.dart';

/// MainScreen serves as the primary home screen for REVOLT VPN.
/// 
/// It provides a dark mode, cyberpunk-inspired visual layout displaying:
/// - Logo and Branding at the top (`Header`)
/// - Session countdown timer displaying remaining time (`ClockDisplay`)
/// - Tap-to-connect action trigger (`ConnectButton`)
/// - Connected status badge displaying tunnel information (`StatusText`)
/// - Bottom bar showing server health status and voluntary support button (`BottomBar`)
class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  // Background base color
  static const Color _bgTop = Color(0xFF0D1117);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgTop,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: _bgTop,
          image: DecorationImage(
            image: AssetImage('assets/background.png'),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(
              Color(0xAA0D1117), // Deep dark tint overlay to guarantee readability of overlay elements
              BlendMode.darken,
            ),
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // ── Main content column ──
              LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: const IntrinsicHeight(
                        child: Column(
                          children: [
                            SizedBox(height: 4),
                            Header(),
                            Spacer(flex: 1),
                            ConnectButton(),
                            SizedBox(height: 24),
                            StatusText(),
                            Spacer(flex: 3),
                            BottomBar(),
                            SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              // ── Info / About buttons (top-right) ──
              const Positioned(
                top: 4,
                right: 4,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GdprButton(),
                    PrivacyPolicyButton(),
                    InfoButton(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

