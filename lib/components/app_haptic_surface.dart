import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';

/// App-wide tap feedback layer.
///
/// Pointer events are observed instead of wiring haptics into every button.
/// Short taps get feedback, while normal scroll gestures are ignored.
class AppHapticSurface extends StatefulWidget {
  final Widget child;

  const AppHapticSurface({super.key, required this.child});

  @override
  State<AppHapticSurface> createState() => _AppHapticSurfaceState();
}

class _PointerStart {
  final Offset position;
  final DateTime time;

  const _PointerStart(this.position, this.time);
}

class _AppHapticSurfaceState extends State<AppHapticSurface> {
  static const double _maxTapTravel = 18;
  static const Duration _maxTapDuration = Duration(milliseconds: 700);

  final Map<int, _PointerStart> _starts = <int, _PointerStart>{};

  bool _supportsHaptics(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  void _onDown(PointerDownEvent event) {
    if (!_supportsHaptics(event.kind)) return;
    _starts[event.pointer] = _PointerStart(event.position, DateTime.now());
  }

  void _onCancel(PointerCancelEvent event) {
    _starts.remove(event.pointer);
  }

  void _onUp(PointerUpEvent event) {
    final start = _starts.remove(event.pointer);
    if (start == null || !_supportsHaptics(event.kind)) return;

    final travelled = (event.position - start.position).distance;
    final elapsed = DateTime.now().difference(start.time);
    if (travelled <= _maxTapTravel && elapsed <= _maxTapDuration) {
      HapticSettings.tap();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }
}
