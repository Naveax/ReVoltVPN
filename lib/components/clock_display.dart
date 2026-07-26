import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/session_timer.dart';

class ClockDisplay extends StatelessWidget {
  const ClockDisplay({super.key});


  @override
  Widget build(BuildContext context) {
    return Consumer<SessionTimer>(
      builder: (context, timer, _) {
        final bool showSyncing = !timer.hasSyncedOnce;

        return SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Center content: countdown + speed  (or syncing placeholder)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showSyncing) ...[
                    // Syncing placeholder — spinner + label
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accent50,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Syncing…',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.accent60,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ] else ...[
                    // Glowing countdown timer
                    Text(
                      timer.formatted,
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textWhite,
                        letterSpacing: 2,
                        shadows: [
                          Shadow(
                            color: AppColors.accent50,
                            blurRadius: 16,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),

                    // Speed indicator
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.speed, color: AppColors.textDim, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          timer.currentSpeedKBps > 0.5
                              ? '${timer.currentSpeedKBps.toStringAsFixed(1)} KB/s'
                              : 'Idle',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textDim,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
