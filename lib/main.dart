import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/ad_manager.dart';
import 'package:revoltvpn/logic/consent_manager.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/intro.dart';

/// The entry point for the REVOLT VPN application.
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
  runApp(const ReVoltApp());
}

/// The root application widget wrapping the app in necessary state providers and themes.
class ReVoltApp extends StatelessWidget {
  const ReVoltApp({super.key});

  @override
  Widget build(BuildContext context) {
    // MultiProvider injects global state controllers down the widget tree.
    return MultiProvider(
      providers: [
        // Manages the VLESS tunnel lifecycle
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
        title: 'ReVolt VPN',
        debugShowCheckedModeBanner: false,
        theme: _buildDarkTheme(),
        home: const IntroScreen(),
      ),
    );
  }

  /// Constructs the global dark theme used across the application.
  ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgDeep,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.cyan,
        secondary: AppColors.cyan,
        surface: AppColors.bgSurface,
      ),
      fontFamily: 'Roboto',
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.bgCard,
        contentTextStyle: const TextStyle(color: AppColors.textWhite),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
      ),
      useMaterial3: true,
    );
  }
}
