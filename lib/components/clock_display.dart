import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/session_timer.dart';

/// ClockDisplay shows a large circular progress ring and the session countdown timer.
/// 
/// The timer text glows electric cyan when a session is active and dims to slate gray when idle.
class ClockDisplay extends StatelessWidget {
  const ClockDisplay({super.key});

  static const Color _cyanGlow = Color(0xFF00E5FF);
  static const Color _dimSlate = Color(0xFF4A5568);

  @override
  Widget build(BuildContext context) {
    return Consumer<SessionTimer>(
      builder: (context, timer, _) {
        final isLive = timer.isRunning;
        final color = isLive ? _cyanGlow : _dimSlate;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Background track ring representing the maximum capacity of the countdown
                  const CustomPaint(
                    size: Size(220, 220),
                    painter: _ArcPainter(
                      progress: 1.0,
                      color: Color.fromRGBO(74, 85, 104, 0.2),
                      strokeWidth: 4,
                    ),
                  ),
                  
                  // Live progress ring showing current remaining time relative to the session limit
                  if (isLive)
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: timer.progress),
                      duration: const Duration(milliseconds: 400),
                      builder: (context, value, _) => CustomPaint(
                        size: const Size(220, 220),
                        painter: _ArcPainter(
                          progress: value,
                          color: _cyanGlow,
                          strokeWidth: 4,
                          glow: true,
                        ),
                      ),
                    ),
                    
                  // Monospaced digital clock display for session countdown
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontFamily: 'RobotoMono',
                      fontSize: 48,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 4,
                      color: color,
                      shadows: isLive
                          ? const [
                              Shadow(
                                color: Color.fromRGBO(0, 229, 255, 0.6),
                                blurRadius: 20,
                              ),
                              Shadow(
                                color: Color.fromRGBO(0, 229, 255, 0.3),
                                blurRadius: 40,
                              ),
                            ]
                          : const [],
                    ),
                    child: Text(timer.formatted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            
            // Subtitle state label below the timer
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                isLive ? 'SESSION ACTIVE' : 'STANDBY',
                key: ValueKey(isLive),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 3,
                  color: isLive
                      ? const Color.fromRGBO(0, 229, 255, 0.7)
                      : const Color.fromRGBO(74, 85, 104, 0.7),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A custom painter to render a circular progress arc or background track ring.
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

    // Optional blurred background paint to create an electric neon glow effect
    if (glow) {
      final glowPaint = Paint()
        ..color = const Color.fromRGBO(0, 229, 255, 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawArc(rect, -pi / 2, 2 * pi * progress, false, glowPaint);
    }

    // Core progress stroke paint
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
