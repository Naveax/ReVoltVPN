import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/session_timer.dart';

class SpeedBox extends StatelessWidget {
  const SpeedBox({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionTimer>(
      builder: (context, timer, _) {
        final speed = timer.currentSpeedKBps > 0.5
            ? '${timer.currentSpeedKBps.toStringAsFixed(1)} KB/s'
            : 'Idle';

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.glassBg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.glassBorder, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.speed, size: 16, color: AppColors.textDim),
              const SizedBox(width: 8),
              Text(speed, style: const TextStyle(
                color: AppColors.textDim, fontSize: 13, fontWeight: FontWeight.w500,
              )),
            ],
          ),
        );
      },
    );
  }
}
