import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/power_settings.dart';

/// Android owns background scheduling and VPN lockdown policy.
///
/// ReVolt can request a Doze exemption and declare Always-on VPN support, but
/// Android intentionally requires the user/admin to enable Always-on and
/// "Block connections without VPN" from system settings.
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

  Future<void> _openVpnPolicy() async {
    final opened = await PowerSettings.openVpnPolicySettings();
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open Android VPN settings on this device.'),
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
            'Use battery exemption for process survival. For leak protection, '
            'enable Android Always-on VPN and Block connections without VPN.',
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
                        ? 'Battery optimisation: disabled for Revolt VPN ✓'
                        : 'Battery optimisation: still active — Android may '
                            'stop background work.',
                style: TextStyle(
                  color: exempt == true ? AppColors.accent : AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Kill-switch: Android lockdown is a system policy. ReVolt never '
                'pretends proxy-only mode is leak-proof.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (exempt == false)
                    OutlinedButton.icon(
                      onPressed: _requestExemption,
                      icon: const Icon(Icons.battery_saver),
                      label: const Text('Allow background activity'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _openVpnPolicy,
                    icon: const Icon(Icons.shield_outlined),
                    label: const Text('Always-on / Kill-switch'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
