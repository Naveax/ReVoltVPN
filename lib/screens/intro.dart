import 'dart:async';
import 'package:flutter/material.dart';
import 'package:paladinvpn/screens/main_screen.dart';

class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  @override
  void initState() {
    super.initState();
    // Wait for 2.5 seconds then smoothly transition to the main screen
    Timer(const Duration(milliseconds: 2500), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 800),
            pageBuilder: (_, __, ___) => const MainScreen(),
            transitionsBuilder: (_, animation, __, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117), // Deep space black background
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App Logo
            Image.asset(
              'assets/logo.png',
              width: 140,
              height: 140,
              errorBuilder: (context, error, stackTrace) {
                // Fallback icon if logo.png is missing or misconfigured
                return const Icon(
                  Icons.shield,
                  size: 140,
                  color: Color(0xFF00E5FF),
                );
              },
            ),
            const SizedBox(height: 30),
            
            // PaladinVPN Text
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
            
            // Loading Circle
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
