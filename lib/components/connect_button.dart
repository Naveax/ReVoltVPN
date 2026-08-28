import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/ad_manager.dart';
import 'package:revoltvpn/logic/haptic_settings.dart';

class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with SingleTickerProviderStateMixin {
  bool _busy = false;
  DateTime _lastTap = DateTime.now();
  AnimationController? _pulse;
  Animation<double>? _pulseAnim;

  double get _pulseValue => _pulseAnim?.value ?? 0.0;

  @override
  void initState() {
    super.initState();
    final pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));
    _pulse = pulse;
    _pulseAnim = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: pulse, curve: Curves.easeInOut));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VpnConnection>().addListener(_onVpnChanged);
    });
  }

  @override
  void dispose() {
    context.read<VpnConnection>().removeListener(_onVpnChanged);
    _pulse?.dispose();
    super.dispose();
  }

  void _onVpnChanged() {
    final vpn = context.read<VpnConnection>();
    if (vpn.status == VpnStatus.connected) {
      _pulse?.repeat(reverse: true);
    } else {
      _pulse?.stop();
      _pulse?.reset();
    }
  }

  Future<void> _handleTap() async {
    final now = DateTime.now();
    if (now.difference(_lastTap).inMilliseconds < 1000) return;
    _lastTap = now;

    final vpn = context.read<VpnConnection>();
    final timer = context.read<SessionTimer>();
    final ad = context.read<AdManager>();

    if (vpn.status == VpnStatus.disconnecting || _busy) return;

    // Feedback belongs to the accepted tap, not to a later network result.
    HapticSettings.tap();

    if (vpn.status == VpnStatus.connected || vpn.status == VpnStatus.connecting) {
      _busy = false;
      await timer.disconnect();
      return;
    }

    setState(() => _busy = true);
    try {
      final adWatched = await ad.showAd('main');
      if (!adWatched && AdManager.adsEnabled) {
        setState(() => _busy = false);
        return;
      }
      final ok = await vpn.connect();
      if (ok) {
        timer.start();
        HapticSettings.success();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnConnection>(
      builder: (context, vpn, _) {
        final isConnected = vpn.status == VpnStatus.connected;
        final spinning = vpn.status == VpnStatus.connecting ||
            vpn.status == VpnStatus.disconnecting;

        return GestureDetector(
          onTap: _handleTap,
          child: _pulseAnim != null
              ? AnimatedBuilder(
                  animation: _pulseAnim!,
                  builder: (_, __) => _buildCircle(isConnected, spinning, _pulseValue),
                )
              : _buildCircle(isConnected, spinning, 0),
        );
      },
    );
  }

  Widget _buildCircle(bool isConnected, bool spinning, double pulse) {
    final glowAlpha = isConnected ? ((0.3 + pulse * 0.25) * 255).round() : 0;
    final glowRadius = isConnected ? 18.0 + (pulse * 14) : 0.0;

    return Container(
      width: 260,
      height: 260,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bgDark,
        border: Border.all(
          color: isConnected ? AppColors.accent : AppColors.slate50,
          width: isConnected ? 2.5 : 1.5,
        ),
        boxShadow: isConnected
            ? [BoxShadow(color: Color.fromARGB(glowAlpha, 255, 214, 0), blurRadius: glowRadius, spreadRadius: glowRadius * 0.3)]
            : [],
      ),
      clipBehavior: Clip.hardEdge,
      child: spinning
          ? const Center(
              child: SizedBox(
                width: 36, height: 36,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.accent70),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(14),
              child: Image.asset('assets/brand.png', fit: BoxFit.contain),
            ),
    );
  }
}
