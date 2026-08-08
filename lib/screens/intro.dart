import 'dart:async';
import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/main_screen.dart';

class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleNavigation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _navigateToMain();
    }
  }

  void _scheduleNavigation() {
    // Brief natural pause — just long enough to perceive the logo.
    Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
        // App is backgrounded — defer navigation until resumed.
        return;
      }
      _navigateToMain();
    });
  }

  void _navigateToMain() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => const MainScreen(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      body: Column(
        children: [
          const Spacer(flex: 7),
          // Image slightly below center
          Center(
            child: Image.asset(
              'assets/brand.png',
              width: 200,
              height: 200,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(
                  Icons.shield,
                  size: 200,
                  color: AppColors.accent,
                );
              },
            ),
          ),
          // Spinner + text paired together below the image
          const SizedBox(height: 8),
          const SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              color: AppColors.accent,
              strokeWidth: 3.0,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Revolt VPN',
            style: TextStyle(
              color: AppColors.textWhite,
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: 2.0,
            ),
          ),
          const Spacer(flex: 5),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
