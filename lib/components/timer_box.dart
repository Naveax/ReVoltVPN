import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class TimerBox extends StatelessWidget {
  const TimerBox({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<SessionTimer, VpnConnection>(
      builder: (context, timer, vpn, _) {
        final isConnecting = vpn.status == VpnStatus.connecting;
        final isSyncing = vpn.status == VpnStatus.connected && !timer.hasSyncedOnce;
        final showIndicator = isConnecting || isSyncing;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.slate15),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Countdown text (always visible) ──────────────────────
              Text(
                timer.hasSyncedOnce ? timer.formatted : '00:00:00',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: timer.hasSyncedOnce
                      ? AppColors.textWhite
                      : AppColors.slate70,
                  letterSpacing: 2,
                  shadows: timer.hasSyncedOnce
                      ? const [
                          Shadow(
                            color: AppColors.accent50,
                            blurRadius: 16,
                          ),
                        ]
                      : [],
                ),
              ),

              // ── Syncing indicator (only shown while connecting or
              //     waiting for the first server poll) ──────────────────
              if (showIndicator) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accent60,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isConnecting ? 'Connecting…' : 'Syncing…',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.accent60,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
