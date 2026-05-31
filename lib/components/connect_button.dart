import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/logic/session_timer.dart';
import 'package:paladinvpn/components/clock_display.dart';

class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  static const Color _cyanGlow = Color(0xFF00E5FF);
  static const Color _bgDark = Color(0xFF1A202C);

  bool _inCooldown = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Listen to VpnConnection changes to drive the pulse animation
    // from outside build(), keeping build() pure.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VpnConnection>().addListener(_onVpnStateChanged);
    });
  }

  @override
  void dispose() {
    context.read<VpnConnection>().removeListener(_onVpnStateChanged);
    _pulseController.dispose();
    super.dispose();
  }

  void _onVpnStateChanged() {
    if (!mounted) return;
    final isConnected = context.read<VpnConnection>().status == VpnStatus.connected;
    if (isConnected && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!isConnected && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  void _handleTap() async {
    if (_inCooldown) return;

    setState(() => _inCooldown = true);
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) setState(() => _inCooldown = false);
    });

    final vpn = context.read<VpnConnection>();
    final timer = context.read<SessionTimer>();

    if (vpn.status == VpnStatus.connected) {
      vpn.disconnect();
      timer.stop();
    } else if (vpn.status == VpnStatus.disconnected ||
               vpn.status == VpnStatus.error) {
      final success = await vpn.connect();
      if (success) {
        timer.start('main_ad');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<VpnConnection, SessionTimer>(
      builder: (context, vpn, timer, _) {
        final isConnected = vpn.status == VpnStatus.connected;
        final isConnecting = vpn.status == VpnStatus.connecting;

        return GestureDetector(
          onTap: (isConnecting || _inCooldown) ? null : _handleTap,
          child: AnimatedBuilder(
            animation: _pulseAnim,
            builder: (context, child) {
              final glowRadius = isConnected ? 20.0 + (_pulseAnim.value * 15.0) : 0.0;
              final glowAlpha = isConnected
                  ? ((0.3 + _pulseAnim.value * 0.2) * 255).round()
                  : 0;

              return Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _bgDark,
                  border: Border.all(
                    color: _inCooldown
                        ? Colors.grey.withValues(alpha: 0.5)
                        : isConnected
                            ? _cyanGlow
                            : isConnecting
                                ? const Color.fromRGBO(0, 229, 255, 0.5)
                                : const Color.fromRGBO(74, 85, 104, 0.5),
                    width: isConnected && !_inCooldown ? 3 : 2,
                  ),
                  boxShadow: isConnected
                      ? [
                          BoxShadow(
                            color: Color.fromARGB(glowAlpha, 0, 229, 255),
                            blurRadius: glowRadius,
                            spreadRadius: glowRadius * 0.3,
                          ),
                        ]
                      : const [],
                ),
                child: Center(
                  child: isConnected
                    ? const ClockDisplay()
                    : _buildDisconnectedIcon(vpn.status, _inCooldown),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildDisconnectedIcon(VpnStatus status, bool inCooldown) {
    if (status == VpnStatus.connecting || status == VpnStatus.disconnecting) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: Color.fromRGBO(0, 229, 255, 0.7),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          inCooldown ? Icons.hourglass_bottom : Icons.power_settings_new,
          size: 64,
          color: inCooldown ? Colors.grey : const Color.fromRGBO(74, 85, 104, 0.7),
        ),
        const SizedBox(height: 12),
        Text(
          inCooldown ? 'PLEASE WAIT' : 'TAP TO CONNECT',
          style: TextStyle(
            color: inCooldown ? Colors.grey : const Color.fromRGBO(74, 85, 104, 0.9),
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}
