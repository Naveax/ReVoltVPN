import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/screens/main_screen.dart';
import 'package:revoltvpn/screens/settings/in_settings/rain.dart';
import 'package:revoltvpn/screens/settings/in_settings/lightning.dart';

class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> with WidgetsBindingObserver {
  static const _minDisplay = Duration(milliseconds: 500);
  static const _bootTimeout = Duration(seconds: 8);

  String _status = 'Starting secure engine…';
  bool _bootComplete = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _navigateIfReady();
  }

  Future<void> _boot() async {
    final elapsed = Stopwatch()..start();
    final vpn = context.read<VpnConnection>();

    // The overlays and haptic layer read these before MainScreen mounts.
    final settingsPrefs = Future.wait([
      loadRainPref(),
      loadLightningPref(),
      HapticSettings.initialize(),
    ]);

    try {
      await vpn.ready.timeout(_bootTimeout);
    } on TimeoutException {
      debugPrint('[Boot] Engine init exceeded ${_bootTimeout.inSeconds}s '
          '— continuing to the main screen anyway.');
    } catch (e) {
      debugPrint('[Boot] Engine init error: $e');
    }

    try {
      await settingsPrefs;
    } catch (e) {
      debugPrint('[Boot] Settings prefs load failed, using defaults: $e');
    }

    if (!mounted) return;
    setState(() => _status = 'Ready');

    final remaining = _minDisplay - elapsed.elapsed;
    if (remaining > Duration.zero) await Future.delayed(remaining);

    if (!mounted) return;
    _bootComplete = true;
    _navigateIfReady();
  }

  void _navigateIfReady() {
    if (!mounted || _navigated || !_bootComplete) return;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    _navigated = true;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
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
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              _status,
              key: ValueKey(_status),
              style: const TextStyle(
                color: AppColors.textDim,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Spacer(flex: 5),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
