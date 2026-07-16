import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/logic/session_timer.dart';
import 'package:paladinvpn/logic/ad_manager.dart';
import 'package:paladinvpn/components/online_dot.dart';
import 'package:paladinvpn/components/watch_ad_button.dart';

/// BottomBar is the bottom utility panel that surfaces server connectivity status
/// and offers the user an option to support the server when the VPN tunnel is active.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key});

  static const Color _cardBg = Color(0xFF1E2533);

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
            color: _cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color.fromRGBO(74, 85, 104, 0.15),
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
              const Spacer(),
              // Support button — only visible while connected AND ads are enabled
              if (isConnected && AdManager.adsEnabled) const WatchAdButton(),
            ],
          ),
        );
      },
    );
  }
}
