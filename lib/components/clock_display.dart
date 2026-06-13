import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/session_timer.dart';

/// ClockDisplay renders inside the ConnectButton circle when the VPN is active.
///
/// Shows a circular quota-progress arc, a glowing countdown timer, and the
/// current transfer speed — all sized to fit within the 260px button.
///
/// Before the first server sync arrives, a subtle "Syncing…" placeholder
/// is shown instead of a misleading 00:00:00.
class ClockDisplay extends StatelessWidget {
  const ClockDisplay({super.key});

  static const Color _cyanGlow = Color(0xFF00E5FF);

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
                        color: Color.fromRGBO(0, 229, 255, 0.5),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Syncing…',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color.fromRGBO(0, 229, 255, 0.6),
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
                        color: Colors.white,
                        letterSpacing: 2,
                        shadows: [
                          Shadow(
                            color: Color.fromRGBO(0, 229, 255, 0.5),
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
                        const Icon(Icons.speed, color: Colors.white54, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          timer.currentSpeedKbps > 0.5
                              ? '${timer.currentSpeedKbps.toStringAsFixed(1)} KB/s'
                              : 'Idle',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
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
