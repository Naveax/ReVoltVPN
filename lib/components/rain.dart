import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:revoltvpn/screens/settings/in_settings/rain.dart';

/// Subtle animated rain effect — sits behind all UI as a full-screen overlay.
///
/// Usage (in a Stack, as the first child so it renders behind everything):

class RainEffect extends StatefulWidget {
  final int dropCount;

  final Color color;

  final double minLength;

  final double maxLength;

  final double windDrift;

  const RainEffect({
    super.key,
    this.dropCount = 150,
    this.color = const Color(0xFFE8EAF6),
    this.minLength = 12,
    this.maxLength = 44,
    this.windDrift = 4.0,
  });

  @override
  State<RainEffect> createState() => _RainEffectState();
}

class _RainEffectState extends State<RainEffect>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _drops = <_Drop>[];
  final _random = Random();
  Duration _last = Duration.zero;

  // Lifecycle

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < widget.dropCount; i++) {
      _drops.add(_Drop.spawn(_random, widget.minLength, widget.maxLength));
    }
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // Tick

  void _onTick(Duration now) {
    double dt = 0.016; // ~60 fps fallback on first tick
    if (_last != Duration.zero) {
      dt = (now - _last).inMicroseconds / 1000000.0;
      dt = dt.clamp(0.0, 0.1); 
    }
    _last = now;

    for (final d in _drops) {
      d.y += d.speed * dt;
      if (d.y > 1.08) {
        d.spawn(_random, widget.minLength, widget.maxLength);
        d.y = -0.06 - _random.nextDouble() * 0.08; 
      }
    }
    setState(() {}); 
  }

  // Build

  @override
  Widget build(BuildContext context) {
    if (!rainEnabled) return const SizedBox.shrink();
    return CustomPaint(
      painter: _RainPainter(
        drops: _drops,
        color: widget.color,
        windDrift: widget.windDrift,
      ),
      size: Size.infinite,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Drop model
// ═══════════════════════════════════════════════════════════════════════════

class _Drop {
  double x; 
  double y; 
  double speed; 
  double length; 
  double opacity; 

  _Drop({
    required this.x,
    required this.y,
    required this.speed,
    required this.length,
    required this.opacity,
  });

  /// Create a drop at a random position anywhere on screen.
  factory _Drop.spawn(Random r, double minLen, double maxLen) {
    return _Drop(
      x: r.nextDouble(),
      y: r.nextDouble(),
      speed: 0.30 + r.nextDouble() * 0.55,
      length: minLen + r.nextDouble() * (maxLen - minLen),
      opacity: 0.05 + r.nextDouble() * 0.12,
    );
  }

  /// Re-randomise all properties (call when recycling a drop to the top).
  void spawn(Random r, double minLen, double maxLen) {
    x = r.nextDouble();
    speed = 0.30 + r.nextDouble() * 0.55;
    length = minLen + r.nextDouble() * (maxLen - minLen);
    opacity = 0.05 + r.nextDouble() * 0.12;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Painter
// ═══════════════════════════════════════════════════════════════════════════

class _RainPainter extends CustomPainter {
  final List<_Drop> drops;
  final Color color;
  final double windDrift;

  _RainPainter({
    required this.drops,
    required this.color,
    required this.windDrift,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.5;

    for (final d in drops) {
      final sx = d.x * size.width;
      final sy = d.y * size.height;
      final ex = sx - windDrift; // slight leftward slant
      final ey = sy + d.length;

      paint.color = color.withAlpha((d.opacity * 255).round());
      canvas.drawLine(Offset(sx, sy), Offset(ex, ey), paint);
    }
  }

  @override
  bool shouldRepaint(_RainPainter old) => true; // always animating
}
