import 'dart:async';
import 'package:flutter/material.dart';
import 'package:paladinvpn/screens/main_screen.dart';

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
      backgroundColor: const Color(0xFF0D1117),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/logo.png',
              width: 140,
              height: 140,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(
                  Icons.shield,
                  size: 140,
                  color: Color(0xFF00E5FF),
                );
              },
            ),
            const SizedBox(height: 30),
            const Text(
              'PALADIN VPN',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 2.0,
              ),
            ),
            const SizedBox(height: 60),
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                color: Color(0xFF00E5FF),
                strokeWidth: 3.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
