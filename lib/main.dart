import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/ad_manager.dart';
import 'package:revoltvpn/logic/server_list.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/intro.dart';
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

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
        // lazy: false — the native VLESS engine takes real time to start, and
        // providers are lazy by default, so it used to begin initialising only
        // once MainScreen first read it, i.e. *after* the loading screen was
        // gone. Constructing it eagerly moves that work under the intro, which
        // now awaits VpnConnection.ready before navigating.
        ChangeNotifierProvider(create: (_) => VpnConnection(), lazy: false),
        ChangeNotifierProxyProvider<VpnConnection, SessionTimer>(
          create: (ctx) => SessionTimer(vpnConnection: ctx.read<VpnConnection>()),
          update: (_, vpn, prev) => prev ?? SessionTimer(vpnConnection: vpn),
        ),
        ChangeNotifierProvider(create: (_) => AdManager()),
        ChangeNotifierProvider(create: (_) => ServerList()..init(), lazy: false),
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
