import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';

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
            color: isOnline ? AppColors.green : AppColors.slate,
            boxShadow: isOnline
                ? const [
                    BoxShadow(
                      color: AppColors.green50,
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
                ? AppColors.textDim
                : AppColors.slate,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}
