import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/power_settings.dart';

class BackgroundReliabilityTile extends StatefulWidget {
  const BackgroundReliabilityTile({super.key});

  @override
  State<BackgroundReliabilityTile> createState() =>
      _BackgroundReliabilityTileState();
}

class _BackgroundReliabilityTileState extends State<BackgroundReliabilityTile>
    with WidgetsBindingObserver {
  bool? _batteryExempt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final exempt = await PowerSettings.isBatteryOptimisationDisabled();
    if (mounted) setState(() => _batteryExempt = exempt);
  }

  Future<void> _requestExemption() async {
    final opened = await PowerSettings.requestDisableBatteryOptimisation();
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open battery settings on this device.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final exempt = _batteryExempt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ListTile(
          title: Text(
            'Background reliability',
            style: TextStyle(color: AppColors.textWhite, fontSize: 15),
          ),
          subtitle: Text(
            'ReVolt keeps an active connection in an Android foreground VPN '
            'service. Battery exemption is optional extra protection for '
            'devices that aggressively restrict background work.',
            style: TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                exempt == null
                    ? 'Battery optimisation: checking…'
                    : exempt
                        ? 'Battery optimisation: unrestricted for ReVolt VPN ✓'
                        : 'Battery optimisation: system managed. ReVolt will '
                            'still use its foreground VPN service; unrestricted '
                            'mode can improve reliability on aggressive devices.',
                style: TextStyle(
                  color: exempt == true ? AppColors.accent : AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
              if (exempt == false) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _requestExemption,
                  icon: const Icon(Icons.battery_saver),
                  label: const Text('Allow unrestricted background'),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'TUN mode is kept fail-closed while its native route recovers. '
                'SOCKS5 mode has no Android VPN interface, so Android VPN '
                'Always-on/lockdown settings do not apply to it. ReVolt does '
                'not advertise reboot restoration because per-session state '
                'cannot be reconstructed safely after a reboot.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
