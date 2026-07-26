import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/session_timer.dart';

/// TimerBox — a rectangular card showing the session countdown.
class TimerBox extends StatelessWidget {
  const TimerBox({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionTimer>(
      builder: (context, timer, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.slate15),
          ),
          child: Text(
            timer.hasSyncedOnce ? timer.formatted : '00:00:00',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: AppColors.textWhite,
              letterSpacing: 2,
            ),
          ),
        );
      },
    );
  }
}
