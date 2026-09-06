import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/components/online_dot.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<VpnConnection, SessionTimer>(
      builder: (context, vpn, timer, _) {
        final isConnected = vpn.status == VpnStatus.connected;
        final isConnecting = vpn.status == VpnStatus.connecting;
        final serverHealthy =
            vpn.serverReachable || (isConnected && timer.hasSyncedOnce);
        final sessionOrTunnelHealthy = timer.hasSyncedOnce || vpn.serverReachable;

        final statusLabel = isConnected
            ? (sessionOrTunnelHealthy ? 'Online' : 'Syncing…')
            : (isConnecting
                ? 'Connecting…'
                : (vpn.serverReachable ? 'Ready' : 'Offline'));

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.slate15),
                ),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/finland_flag_256.png',
                      width: 20,
                      height: 20,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Helsinki, Finland',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.slate15),
                ),
                child: Row(
                  children: [
                    OnlineDot(
                      isOnline: serverHealthy,
                      label: statusLabel,
                    ),
                    const Spacer(),
                    if (vpn.networkTransport != 'unknown' &&
                        vpn.networkTransport != 'none')
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          vpn.networkTransport,
                          style: const TextStyle(
                            color: AppColors.textDim,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (isConnected)
                      const Icon(
                        Icons.lock,
                        color: AppColors.green50,
                        size: 14,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
