import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/components/online_dot.dart';

/// BottomBar is the bottom utility panel that surfaces server connectivity status
/// and offers the user an option to support the server when the VPN tunnel is active.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key});

  // Dark card background color for high contrast overlay
  static const Color _cardBg = Color(0xFF1E2533);

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnConnection>(
      builder: (context, vpn, _) {
        final isOnline = vpn.status == VpnStatus.connected;

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
              // Displays the server online/offline chip
              OnlineDot(isOnline: isOnline),
            ],
          ),
        );
      },
    );
  }
}
