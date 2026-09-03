import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/power_settings.dart';

/// Android may restrict background work when battery optimisation is active.
/// Surface the OS setting we can actually detect and request; do not promise
/// reboot/Always-on restoration that the per-session runtime cannot guarantee.
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
            'Android may restrict background work to save power. ReVolt only '
            'shows the system control it can verify.',
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
                        : 'Battery optimisation: active — Android may stop '
                            'background VPN work.',
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
                  label: const Text('Allow background activity'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
