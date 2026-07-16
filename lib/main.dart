import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/logic/session_timer.dart';
import 'package:paladinvpn/logic/ad_manager.dart';
import 'package:paladinvpn/logic/consent_manager.dart';
import 'package:paladinvpn/screens/main_screen.dart';
import 'package:paladinvpn/screens/intro.dart';

/// The entry point for the Paladin VPN application.
void main() async {
  // Ensure that the Flutter engine is fully initialized before using platform channels
  // (e.g., for SystemChrome or MobileAds).
  WidgetsFlutterBinding.ensureInitialized();

  // Lock the application to portrait orientation since the dashboard is a single-screen utility app
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Configure a stealth system bar layout: transparent status bar with light icons,
  // blending seamlessly into the dark background gradient.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D1117), // Deep space black
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // ── GDPR Consent (Google UMP) ──────────────────────────────────────────
  // Must run BEFORE MobileAds initialization. Shows consent dialog to
  // EEA/UK users; no-op for everyone else.
  await ConsentManager.requestConsentIfNeeded();

  // ── Initialize AdMob ───────────────────────────────────────────────────
  // Only after consent is resolved so AdMob respects user preferences.
  await MobileAds.instance.initialize();

  // Inflate the root widget
  runApp(const PaladinApp());
}

/// The root application widget wrapping the app in necessary state providers and themes.
class PaladinApp extends StatelessWidget {
  const PaladinApp({super.key});

  @override
  Widget build(BuildContext context) {
    // MultiProvider injects global state controllers down the widget tree.
    return MultiProvider(
      providers: [
        // Manages the WireGuard tunnel lifecycle
        ChangeNotifierProvider(create: (_) => VpnConnection()),
        
        // Manages the 1-hour session clock.
        // Uses ProxyProvider to automatically inject the VpnConnection, 
        // allowing the timer to auto-disconnect the VPN when time expires.
        ChangeNotifierProxyProvider<VpnConnection, SessionTimer>(
          create: (ctx) => SessionTimer(
            vpnConnection: ctx.read<VpnConnection>(),
          ),
          update: (_, vpn, prev) =>
              prev ?? SessionTimer(vpnConnection: vpn),
        ),

        // Manages rewarded ad lifecycle — preloads on startup.
        ChangeNotifierProvider(create: (_) => AdManager()),
      ],
      child: MaterialApp(
        title: 'Paladin VPN',
        debugShowCheckedModeBanner: false,
        theme: _buildDarkTheme(),
        home: const IntroScreen(),
      ),
    );
  }

  /// Constructs the global dark theme used across the application.
  ThemeData _buildDarkTheme() {
    const cyanAccent = Color(0xFF00E5FF);
    const bgDark = Color(0xFF0D1117);

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,
      colorScheme: const ColorScheme.dark(
        primary: cyanAccent,
        secondary: cyanAccent,
        surface: Color(0xFF151C28),
      ),
      fontFamily: 'Roboto',
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF1E2533),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
      ),
      useMaterial3: true,
    );
  }
}
