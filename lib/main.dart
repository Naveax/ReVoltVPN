import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/ad_manager.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/screens/intro.dart';

const _startupPreferenceTimeout = Duration(seconds: 5);

Future<void> _initializePreferenceLayer(
  String name,
  Future<void> Function() initialize,
) async {
  try {
    await initialize().timeout(_startupPreferenceTimeout);
  } catch (error, stack) {
    debugPrint('[Startup] $name initialization failed: $error');
    debugPrintStack(stackTrace: stack);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Install global handlers before any plugin or preference initialization.
  // Startup failures must not vanish before the application has a chance to
  // report or recover from them.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[PlatformError] $error');
    debugPrintStack(stackTrace: stack);
    return false;
  };

  await _initializePreferenceLayer('Haptics', HapticSettings.initialize);
  await _initializePreferenceLayer(
    'Connection settings',
    ConnectionSettings.initialize,
  );

  try {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp])
        .timeout(_startupPreferenceTimeout);
  } catch (error, stack) {
    debugPrint('[Startup] Orientation setup failed: $error');
    debugPrintStack(stackTrace: stack);
  }

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D1117),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const ReVoltApp());
}

class ReVoltApp extends StatelessWidget {
  const ReVoltApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => VpnConnection(), lazy: false),
        ChangeNotifierProxyProvider<VpnConnection, SessionTimer>(
          // Eager, like VpnConnection: the timer has to be listening before the
          // engine reports an already-running tunnel, not after the intro.
          lazy: false,
          create: (ctx) =>
              SessionTimer(vpnConnection: ctx.read<VpnConnection>()),
          update: (_, vpn, prev) =>
              prev ?? SessionTimer(vpnConnection: vpn),
        ),
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

  ThemeData _buildDarkTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgDeep,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.accent,
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
