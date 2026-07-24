import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/session_timer.dart';
import 'package:revoltvpn/logic/ad_manager.dart';
import 'package:revoltvpn/components/clock_display.dart';

class ConnectButton extends StatefulWidget {
  const ConnectButton({super.key});

  @override
  State<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends State<ConnectButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

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

    final vpn = context.read<VpnConnection>();
    final timer = context.read<SessionTimer>();

    if (vpn.status == VpnStatus.connected) {
      // Disconnect — await the full teardown so the notification and UI
      // stay in sync with the actual tunnel state.
      HapticFeedback.lightImpact();
      timer.stop();
      await vpn.disconnect();
      // Short cooldown to prevent accidental immediate reconnect
      setState(() => _inCooldown = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _inCooldown = false);
      });
    } else if (vpn.status == VpnStatus.disconnected ||
               vpn.status == VpnStatus.error) {
      HapticFeedback.lightImpact();

      // ── Show rewarded ad ──
      // In production the server creates the session via AdMob SSV callback
      // only after a real ad is watched.  The debug bypass in HivemindService
      // handles session creation when adsEnabled is false.
      final adMgr = context.read<AdManager>();
      final adWatched = await adMgr.showAd('main_ad');
      if (AdManager.adsEnabled && !adWatched) {
        // User closed the ad before earning the reward — don't connect.
        return;
      }

      final success = await vpn.connect();
      if (success) {
        timer.start('main_ad');
        // Only apply cooldown on success — failures clear immediately
        setState(() => _inCooldown = true);
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted) setState(() => _inCooldown = false);
        });
      }
      // On failure, check if it's a permission issue and offer recovery.
      if (!success && mounted) {
        final msg = vpn.errorMessage ?? '';
        if (msg.contains('permission') || msg.contains('Permission')) {
          _showPermissionDialog();
        }
      }
    }
  }

  /// Shows a dialog guiding the user to grant the VPN permission in
  /// Android system settings, since there's no way to re-prompt the
  /// native VpnService dialog after the first denial.
  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgDark,
        title: const Text('VPN Permission Required',
            style: TextStyle(color: AppColors.textWhite)),
        content: const Text(
          'ReVoltVPN needs permission to set up a VPN connection.\n\n'
          'Since the permission was denied once, Android won\'t ask again. '
          'To grant it manually:\n\n'
          '1. Open your device Settings\n'
          '2. Go to Apps → ReVoltVPN\n'
          '3. Tap "VPN" and enable it\n'
          '4. Return to ReVoltVPN and tap connect',
          style: TextStyle(color: AppColors.textMuted),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.cyan,
            ),
            child: const Text('Got it',
                style: TextStyle(color: AppColors.bgDeep)),
          ),
        ],
      ),
    );
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
                  color: AppColors.bgDark,
                  border: Border.all(
                    color: _inCooldown
                        ? Colors.grey.withValues(alpha: 0.5)  // dynamic, OK inline
                        : isConnected
                            ? AppColors.cyan
                            : isConnecting
                                ? AppColors.cyan50
                                : AppColors.slate50,
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
          color: AppColors.cyan70,
        ),
      );
    }
    // Determine the right label for the disconnected state
    String label;
    IconData icon;
    Color tint;

    if (inCooldown) {
      label = 'PLEASE WAIT';
      icon  = Icons.hourglass_bottom;
      tint  = Colors.grey; // dynamic, OK inline
    } else if (status == VpnStatus.error) {
      label = 'TRY AGAIN';
      icon  = Icons.refresh;
      tint  = AppColors.red; // soft red — something went wrong
    } else {
      label = 'TAP TO CONNECT';
      icon  = Icons.power_settings_new;
      tint  = AppColors.slate70;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: tint),
        const SizedBox(height: 12),
        Text(
          label,
          style: TextStyle(
            color: tint,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}
