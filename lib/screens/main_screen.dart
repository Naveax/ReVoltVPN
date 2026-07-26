import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/components/connect_button.dart';
import 'package:revoltvpn/components/sidebar_drawer.dart';
import 'package:revoltvpn/components/timer_box.dart';
import 'package:revoltvpn/components/speed_box.dart';
import 'package:revoltvpn/components/status_bar.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      endDrawer: const SidebarDrawer(),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: AppColors.bgDeep,
          image: DecorationImage(
            image: AssetImage('assets/background.png'),
            fit: BoxFit.cover,
            colorFilter: ColorFilter.mode(AppColors.bgOverlay, BlendMode.darken),
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 0,
                right: 4,
                child: Builder(
                  builder: (ctx) => IconButton(
                    icon: const Icon(Icons.menu, color: AppColors.textWhite, size: 28),
                    onPressed: () => Scaffold.of(ctx).openEndDrawer(),
                    tooltip: 'Menu', splashRadius: 24,
                  ),
                ),
              ),

              Positioned(
                top: 100, // <-- CHANGE ME: timer distance from top
                left: 0,
                right: 0,
                child: const Center(child: TimerBox()),
              ),

              Positioned(
                top: 250, // <-- CHANGE ME: connect button from top
                left: 0,
                right: 0,
                child: const Center(child: ConnectButton()),
              ),

              Positioned(
                top: 520, // <-- CHANGE ME: speed box from top
                left: 0,
                right: 0,
                child: const Center(child: SpeedBox()),
              ),

              Positioned(
                bottom: 16, // <-- CHANGE ME: status bar from bottom
                left: 0,
                right: 0,
                child: const StatusBar(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
