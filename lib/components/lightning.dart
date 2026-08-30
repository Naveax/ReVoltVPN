import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/screens/settings/in_settings/lightning.dart';

/// 2D lightning bolt — a jagged yellow line from top to bottom with glow.

class LightningEffect extends StatefulWidget {

  final int minIntervalSec;

  final int maxIntervalSec;

  final double doubleChance;

  const LightningEffect({
    super.key,
    this.minIntervalSec = 2,
    this.maxIntervalSec = 10,
    this.doubleChance = 0.2,
  });

  @override
  State<LightningEffect> createState() => _LightningEffectState();
}

class _LightningEffectState extends State<LightningEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _timer;
  final _random = Random();

  LightningBolt? _bolt;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    lightningEnabled.addListener(_onEnabledChanged);
    if (lightningEnabled.value) _scheduleNext();
  }

  void _onEnabledChanged() {
    if (lightningEnabled.value) {
      _scheduleNext();
    } else {
      _timer?.cancel();
      _ctrl.stop();
      _bolt = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    lightningEnabled.removeListener(_onEnabledChanged);
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _scheduleNext() {
    final secs = widget.minIntervalSec +
        _random.nextInt(widget.maxIntervalSec - widget.minIntervalSec + 1);
    _timer = Timer(Duration(seconds: secs), _strike);
  }

  void _strike() {
    if (!mounted || !lightningEnabled.value) return;
    _bolt = LightningBolt.random(_random);
    _ctrl.forward(from: 0.0);

    if (_random.nextDouble() < widget.doubleChance) {
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted && lightningEnabled.value) {
          _bolt = LightningBolt.random(_random);
          _ctrl.forward(from: 0.0);
        }
      });
    }

    _scheduleNext();
  }

  /// Sharp flash curve: quick on, quick off.  No slow fade.
  double _opacity(double t) {
    if (t < 0.08) return t / 0.08;           // fast ramp
    return 1.0 - ((t - 0.08) / 0.92);        // linear decay
  }

  @override
  Widget build(BuildContext context) {
    if (!lightningEnabled.value) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        final raw = _opacity(_ctrl.value);
        if (raw <= 0.02 || _bolt == null) return const SizedBox.shrink();

        return IgnorePointer(
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final sz = Size(constraints.maxWidth, constraints.maxHeight);
              return CustomPaint(
                size: sz,
                painter: _LightningPainter(
                  bolt: _bolt!,
                  opacity: raw,
                ),
              );
            },
          ),
        );
      },
    );
  }
}


/// A single bolt defined by a list of 2D points (0.0–1.0 in width×height space).
class LightningBolt {
  final List<Offset> mainPath;
  final List<List<Offset>> branches; // 0–2 forks off the main path

  const LightningBolt({required this.mainPath, this.branches = const []});

  /// Generate a random bolt.  The path always starts near the top-center
  /// and ends near the bottom, zigzagging left/right along the way.
  factory LightningBolt.random(Random rng) {
    final points = <Offset>[];

    // Start: top, slight horizontal offset
    double x = 0.5 + (rng.nextDouble() - 0.5) * 0.15;
    points.add(Offset(x, 0.0));

    // Zigzag down — 6–10 segments
    final segments = 6 + rng.nextInt(5);
    for (int i = 1; i < segments; i++) {
      final y = i / segments;
      // Random horizontal offset — each segment adds jitter
      x += (rng.nextDouble() - 0.5) * 0.25;
      x = x.clamp(0.05, 0.95); // stay on screen
      points.add(Offset(x, y));
    }

    // End: bottom
    points.add(Offset(x.clamp(0.1, 0.9), 1.0));

    // Branches — 0–2 forks from random points along the main path
    final branches = <List<Offset>>[];
    final branchCount = rng.nextInt(3);
    for (int b = 0; b < branchCount; b++) {
      final branch = <Offset>[];
      final startIdx = 1 + rng.nextInt(points.length - 2);
      final start = points[startIdx];
      branch.add(start);

      double bx = start.dx;
      double by = start.dy;
      final branchLen = 2 + rng.nextInt(3);
      for (int j = 0; j < branchLen; j++) {
        by += (0.05 + rng.nextDouble() * 0.12);
        bx += (rng.nextDouble() - 0.5) * 0.3;
        bx = bx.clamp(0.02, 0.98);
        by = by.clamp(0.0, 1.0);
        branch.add(Offset(bx, by));
      }
      branches.add(branch);
    }

    return LightningBolt(mainPath: points, branches: branches);
  }
}


class _LightningPainter extends CustomPainter {
  final LightningBolt bolt;
  final double opacity;

  _LightningPainter({required this.bolt, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    final toScreen = (Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    final scaledMain = bolt.mainPath.map(toScreen).toList();
    final scaledBranches = bolt.branches
        .map((b) => b.map(toScreen).toList())
        .toList();

    final baseColor = AppColors.accent.withAlpha((opacity * 255).round());
    final glowColor = AppColors.accent.withAlpha((opacity * 0.35 * 255).round());

    // Glow
    final glowPaint = Paint()
      ..color = glowColor
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
      ..style = PaintingStyle.stroke;

    _drawPath(canvas, scaledMain, scaledBranches, glowPaint);

    // Core
    final corePaint = Paint()
      ..color = baseColor
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    _drawPath(canvas, scaledMain, scaledBranches, corePaint);

    // Hot center
    if (opacity > 0.6) {
      final hotPaint = Paint()
        ..color = Colors.white.withAlpha((opacity * 180).round())
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      _drawPath(canvas, scaledMain, scaledBranches, hotPaint);
    }
  }

  void _drawPath(Canvas canvas, List<Offset> main,
      List<List<Offset>> branches, Paint paint) {
    final mainPath = Path()..moveTo(main.first.dx, main.first.dy);
    for (int i = 1; i < main.length; i++) {
      mainPath.lineTo(main[i].dx, main[i].dy);
    }
    canvas.drawPath(mainPath, paint);

    for (final branch in branches) {
      final bPath = Path()..moveTo(branch.first.dx, branch.first.dy);
      for (int i = 1; i < branch.length; i++) {
        bPath.lineTo(branch[i].dx, branch[i].dy);
      }
      canvas.drawPath(bPath, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LightningPainter old) =>
      bolt != old.bolt || opacity != old.opacity;
}
