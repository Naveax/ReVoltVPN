import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/components/online_dot.dart';

/// BottomBar is the bottom utility panel that surfaces server connectivity status.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<VpnConnection, SessionTimer>(
      builder: (context, vpn, timer, _) {
        final isConnected = vpn.status == VpnStatus.connected;
        // Health is based on whether we've successfully talked to the
        // server recently — not just whether the VPN tunnel is up.
        final serverHealthy = isConnected && timer.hasSyncedOnce;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.slate15,
            ),
          ),
          child: Row(
            children: [
              // Server online/offline chip
              OnlineDot(
                isOnline: serverHealthy,
                label: isConnected && !timer.hasSyncedOnce
                    ? 'Syncing…'
                    : serverHealthy
                        ? 'Server Online'
                        : 'Disconnected',
              ),
            ],
          ),
        );
      },
    );
  }
}
