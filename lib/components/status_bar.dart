import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/components/online_dot.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<VpnConnection, SessionTimer>(
      builder: (context, vpn, timer, _) {
        final isConnected = vpn.status == VpnStatus.connected;
        final isConnecting = vpn.status == VpnStatus.connecting;
        final serverHealthy = vpn.serverReachable || (isConnected && timer.hasSyncedOnce);

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.slate15),
          ),
          child: Row(
            children: [
              // Connection status — wrapped in Flexible to prevent overflow
              // on narrow screens (the Row must fit both the status text
              // and the online dot without RenderFlex errors).
              if (isConnected) ...[
                Image.asset('assets/finland_flag_256.png', width: 20, height: 20),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text('Helsinki, Finland', style: TextStyle(
                    color: AppColors.accent, fontWeight: FontWeight.w600,
                    fontSize: 13, letterSpacing: 0.5,
                  ), overflow: TextOverflow.ellipsis),
                ),
              ] else ...[
                Icon(
                  isConnecting ? Icons.sync : Icons.shield_outlined,
                  size: 18,
                  color: isConnecting ? AppColors.accent : AppColors.slate70,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    vpn.statusMessage.toUpperCase(),
                    style: TextStyle(
                      color: isConnecting ? AppColors.accent : AppColors.slate70,
                      fontWeight: FontWeight.w600, fontSize: 13, letterSpacing: 1,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],

              const Spacer(),

              // Server health
              OnlineDot(
                isOnline: serverHealthy,
                label: isConnected
                    ? (timer.hasSyncedOnce ? 'Online' : 'Syncing…')
                    : (vpn.serverReachable ? 'Ready' : 'Offline'),
              ),
            ],
          ),
        );
      },
    );
  }
}
