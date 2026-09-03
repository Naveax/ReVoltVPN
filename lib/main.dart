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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await HapticSettings.initialize();
  await ConnectionSettings.initialize();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0D1117),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  FlutterError.onError = (details) {
    debugPrint('[FlutterError] ${details.exception}');
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[PlatformError] $error\n$stack');
    return true;
  };

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
