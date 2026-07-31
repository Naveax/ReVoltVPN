import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/components/connect_button.dart';
import 'package:revoltvpn/components/sidebar_drawer.dart';
import 'package:revoltvpn/components/timer_box.dart';
import 'package:revoltvpn/components/speed_box.dart';
import 'package:revoltvpn/components/status_bar.dart';
import 'package:revoltvpn/components/support_button.dart';
import 'package:revoltvpn/components/rain.dart';
import 'package:revoltvpn/components/lightning.dart';

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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Proportional positioning — fractions of available height.
              // On the reference device (~700 dp) this produces the exact
              // original pixel positions (100, 175, 250, 520) and scales
              // proportionally on taller/shorter screens.
              final h = constraints.maxHeight;
              return Stack(
                children: [
                  // ── Lightning — behind rain so drops stay visible during flash ──
                  const Positioned.fill(child: LightningEffect()),

                  // ── Rain effect — behind all UI, baked into the background ──
                  const Positioned.fill(child: RainEffect()),

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
                    top: h * 0.143,
                    left: 0,
                    right: 0,
                    child: const Center(child: TimerBox()),
                  ),

                  Positioned(
                    top: h * 0.250,
                    left: 0,
                    right: 0,
                    child: const Center(child: SupportButton()),
                  ),

                  Positioned(
                    top: h * 0.357,
                    left: 0,
                    right: 0,
                    child: const Center(child: ConnectButton()),
                  ),

                  Positioned(
                    top: h * 0.743,
                    left: 0,
                    right: 0,
                    child: const Center(child: SpeedBox()),
                  ),

                  const Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: StatusBar(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
