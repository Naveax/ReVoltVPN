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
  final _repaint = ValueNotifier<int>(0);
  Duration _last = Duration.zero;

  // Lifecycle

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < widget.dropCount; i++) {
      _drops.add(
          _Drop.spawn(_random, widget.minLength, widget.maxLength, widget.color));
    }
    _ticker = createTicker(_onTick);
    rainEnabled.addListener(_onEnabledChanged);
    if (rainEnabled.value) _ticker.start();
  }

  @override
  void dispose() {
    rainEnabled.removeListener(_onEnabledChanged);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onEnabledChanged() {
    if (rainEnabled.value) {
      // Ticker elapsed restarts at zero; a stale _last makes the first dt negative.
      _last = Duration.zero;
      _ticker.start();
    } else {
      _ticker.stop();
    }
    if (mounted) setState(() {});
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
        d.spawn(_random, widget.minLength, widget.maxLength, widget.color);
        d.y = -0.06 - _random.nextDouble() * 0.08;
      }
    }
    _repaint.value++;
  }

  // Build

  @override
  Widget build(BuildContext context) {
    if (!rainEnabled.value) return const SizedBox.shrink();
    return CustomPaint(
      painter: _RainPainter(
        drops: _drops,
        windDrift: widget.windDrift,
        repaint: _repaint,
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
  Color color;

  _Drop({
    required this.x,
    required this.y,
    required this.speed,
    required this.length,
    required this.color,
  });

  /// Create a drop at a random position anywhere on screen.
  factory _Drop.spawn(Random r, double minLen, double maxLen, Color base) {
    return _Drop(
      x: r.nextDouble(),
      y: r.nextDouble(),
      speed: 0.30 + r.nextDouble() * 0.55,
      length: minLen + r.nextDouble() * (maxLen - minLen),
      color: base.withAlpha(((0.05 + r.nextDouble() * 0.12) * 255).round()),
    );
  }

  /// Re-randomise all properties (call when recycling a drop to the top).
  void spawn(Random r, double minLen, double maxLen, Color base) {
    x = r.nextDouble();
    speed = 0.30 + r.nextDouble() * 0.55;
    length = minLen + r.nextDouble() * (maxLen - minLen);
    color = base.withAlpha(((0.05 + r.nextDouble() * 0.12) * 255).round());
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Painter
// ═══════════════════════════════════════════════════════════════════════════

class _RainPainter extends CustomPainter {
  final List<_Drop> drops;
  final double windDrift;

  _RainPainter({
    required this.drops,
    required this.windDrift,
    required Listenable repaint,
  }) : super(repaint: repaint);

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

      paint.color = d.color;
      canvas.drawLine(Offset(sx, sy), Offset(ex, ey), paint);
    }
  }

  @override
  bool shouldRepaint(_RainPainter old) => false; // repaint listenable drives frames
}
