import 'package:flutter/material.dart';

/// OnlineDot displays a glowing green dot when the server is online/connected,
/// and a muted gray dot when disconnected.
class OnlineDot extends StatelessWidget {
  /// Represents if the VPN tunnel session is active (online).
  final bool isOnline;

  const OnlineDot({
    super.key,
    required this.isOnline,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Glowing status dot: Green when active, muted gray when inactive.
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOnline ? const Color(0xFF00E676) : const Color(0xFF4A5568),
            boxShadow: isOnline
                ? const [
                    BoxShadow(
                      color: Color.fromRGBO(0, 230, 118, 0.5),
                      blurRadius: 6,
                    ),
                  ]
                : const [],
          ),
        ),
        const SizedBox(width: 10),
        
        // Dynamic status text label
        Text(
          isOnline ? 'Server Online' : 'Disconnected',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isOnline
                ? const Color.fromRGBO(255, 255, 255, 0.8)
                : const Color(0xFF4A5568),
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}
