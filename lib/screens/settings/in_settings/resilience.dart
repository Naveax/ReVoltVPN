import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class ResilienceModeTile extends StatefulWidget {
  const ResilienceModeTile({super.key});

  @override
  State<ResilienceModeTile> createState() => _ResilienceModeTileState();
}

class _ResilienceModeTileState extends State<ResilienceModeTile> {
  ResilienceMode _mode = ConnectionSettings.resilienceMode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ConnectionSettings.initialize();
    if (mounted) setState(() => _mode = ConnectionSettings.resilienceMode);
  }

  bool _vpnBusy() {
    final status = context.read<VpnConnection>().status;
    return status == VpnStatus.connected ||
        status == VpnStatus.connecting ||
        status == VpnStatus.disconnecting;
  }

  Future<void> _change(ResilienceMode? next) async {
    if (next == null || next == _mode) return;
    if (_vpnBusy()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Disconnect before changing resilience mode.'),
        ),
      );
      return;
    }

    await ConnectionSettings.setResilienceMode(next);
    if (mounted) setState(() => _mode = next);
  }

  @override
  Widget build(BuildContext context) {
    final extreme = _mode == ResilienceMode.extreme;

    return Consumer<VpnConnection>(
      builder: (context, vpn, _) {
        final connected = vpn.status == VpnStatus.connected ||
            vpn.status == VpnStatus.connecting;
        final active = connected ? ' Active: ${vpn.activeTransportProfile}.' : '';

        return ListTile(
          title: const Text(
            'Network resilience',
            style: TextStyle(color: AppColors.textWhite, fontSize: 15),
          ),
          subtitle: Text(
            extreme
                ? 'Extreme: keeps the exact server transport unchanged and only retries the same runtime after a real Xray disconnect. Recovery is bounded.$active'
                : 'Standard: keeps the exact server transport unchanged and does not force health-check reconnects.$active',
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<ResilienceMode>(
              value: _mode,
              dropdownColor: AppColors.bgCard,
              onChanged: _change,
              items: const [
                DropdownMenuItem(
                  value: ResilienceMode.standard,
                  child: Text('Standard'),
                ),
                DropdownMenuItem(
                  value: ResilienceMode.extreme,
                  child: Text('Extreme'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
