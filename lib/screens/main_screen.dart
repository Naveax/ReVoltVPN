import 'package:flutter/material.dart';
import 'package:revoltvpn/components/connect_button.dart';
import 'package:revoltvpn/components/data_disclosure_dialog.dart';
import 'package:revoltvpn/components/lightning.dart';
import 'package:revoltvpn/components/rain.dart';
import 'package:revoltvpn/components/sidebar_drawer.dart';
import 'package:revoltvpn/components/speed_box.dart';
import 'package:revoltvpn/components/status_bar.dart';
import 'package:revoltvpn/components/support_button.dart';
import 'package:revoltvpn/components/timer_box.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DataDisclosureDialog.showIfFirstLaunch(context);
    });
  }

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
              final h = constraints.maxHeight;
              return Stack(
                children: [
                  const Positioned.fill(child: LightningEffect()),
                  const Positioned.fill(child: RainEffect()),
                  Positioned(
                    top: 0,
                    right: 4,
                    child: Builder(
                      builder: (ctx) => IconButton(
                        icon: const Icon(
                          Icons.menu,
                          color: AppColors.textWhite,
                          size: 28,
                        ),
                        onPressed: () {
                          HapticSettings.tap();
                          Scaffold.of(ctx).openEndDrawer();
                        },
                        tooltip: 'Menu',
                        splashRadius: 24,
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
