import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';

/// StatusText displays the status of the VPN tunnel.
/// 
/// When connected, it shows the Finnish flag along with the tunnel location ("Helsinki, Finland").
/// When connecting or disconnected, it shows status messages with clean micro-animations.
class StatusText extends StatelessWidget {
  const StatusText({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnConnection>(
      builder: (context, vpn, _) {
        final isConnected = vpn.status == VpnStatus.connected;
        final isConnecting = vpn.status == VpnStatus.connecting;

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Container(
            key: ValueKey(vpn.status),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x22FFFFFF), // Subtle glass effect background
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isConnected
                    ? const Color(0x8800E5FF) // Glowing cyan border when connected
                    : const Color(0x33FFFFFF), // Muted translucent border when disconnected/connecting
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isConnected) ...[
                  // Circular Finnish flag icon representing the active tunnel endpoint
                  Image.asset(
                    'assets/finland_flag_256.png',
                    width: 20,
                    height: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Helsinki, Finland',
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                  ),
                ] else ...[
                  if (isConnecting)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Color(0xFF00E5FF),
                      ),
                    )
                  else
                    const Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: Color(0xAA4A5568),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    vpn.statusMessage.toUpperCase(),
                    style: TextStyle(
                      color: isConnecting
                          ? const Color(0xFF00E5FF)
                          : const Color(0xAA4A5568),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
