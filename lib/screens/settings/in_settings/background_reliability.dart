import 'package:flutter/material.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/power_settings.dart';

/// Keeping the tunnel alive is an OS concern, not an app one.
///
/// Android stops background services of apps that are not exempt from Doze, and
/// removes the whole process group when its task is swiped away. There are
/// exactly two sanctioned ways around that, both requiring one user tap, and
/// neither can be enabled programmatically. This tile surfaces both.
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
    // The exemption is granted in a system dialog, so the only reliable moment
    // to re-read it is when we come back to the foreground.
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

  Future<void> _openVpnSettings() async {
    final opened = await PowerSettings.openVpnSettings();
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open VPN settings.')),
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
            'Android stops background apps to save power. These two settings '
            'are what keep the VPN running when the app is closed.',
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
                        : 'Battery optimisation: still active — the system may '
                            'stop the VPN in the background.',
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
              const SizedBox(height: 16),
              const Text(
                'Always-on VPN keeps the tunnel up even after the app is closed '
                'or the phone restarts. Turn it on for Revolt VPN in Android\'s '
                'VPN settings, and enable "Block connections without VPN" if you '
                'want traffic to stop rather than leak when it drops.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openVpnSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open VPN settings'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
