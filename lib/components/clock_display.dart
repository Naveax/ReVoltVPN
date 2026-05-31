import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/session_timer.dart';

/// ClockDisplay renders inside the ConnectButton circle when the VPN is active.
///
/// Shows a circular quota-progress arc, a glowing countdown timer, and the
/// current transfer speed — all sized to fit within the 260px button.
class ClockDisplay extends StatelessWidget {
  const ClockDisplay({super.key});

  static const Color _cyanGlow = Color(0xFF00E5FF);

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionTimer>(
      builder: (context, timer, _) {
        return SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Background quota track ring
              const CustomPaint(
                size: Size(200, 200),
                painter: _ArcPainter(
                  progress: 1.0,
                  color: Color.fromRGBO(74, 85, 104, 0.2),
                  strokeWidth: 4,
                ),
              ),

              // Live quota progress ring
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: timer.progress),
                duration: const Duration(milliseconds: 400),
                builder: (context, value, _) => CustomPaint(
                  size: const Size(200, 200),
                  painter: _ArcPainter(
                    progress: value,
                    color: _cyanGlow,
                    strokeWidth: 4,
                    glow: true,
                  ),
                ),
              ),

              // Center content: countdown + speed
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                        '${timer.currentSpeedKbps.toStringAsFixed(1)} KB/s',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white54,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;
  final bool glow;

  const _ArcPainter({
    required this.progress,
    required this.color,
    this.strokeWidth = 4,
    this.glow = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height)
        .deflate(strokeWidth / 2);

    if (glow) {
      final glowPaint = Paint()
        ..color = const Color.fromRGBO(0, 229, 255, 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, glowPaint);
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, paint);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.progress != progress || old.color != color;
}
