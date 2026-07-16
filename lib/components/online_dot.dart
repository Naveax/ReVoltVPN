import 'package:flutter/material.dart';

/// OnlineDot displays a glowing green dot when the server is healthy,
/// and a muted gray dot when disconnected or still syncing.
class OnlineDot extends StatelessWidget {
  /// Whether the server has been confirmed reachable.
  final bool isOnline;

  /// Optional custom label. Falls back to "Server Online" / "Disconnected".
  final String? label;

  const OnlineDot({
    super.key,
    required this.isOnline,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final displayLabel = label ??
        (isOnline ? 'Server Online' : 'Disconnected');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Glowing status dot: Green when healthy, muted gray when not.
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
        Text(
          displayLabel,
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
