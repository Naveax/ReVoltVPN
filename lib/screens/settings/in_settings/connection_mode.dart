import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class ConnectionModeTile extends StatefulWidget {
  final ValueChanged<ConnectionMode>? onChanged;

  const ConnectionModeTile({super.key, this.onChanged});

  @override
  State<ConnectionModeTile> createState() => _ConnectionModeTileState();
}

class _ConnectionModeTileState extends State<ConnectionModeTile> {
  ConnectionMode _mode = ConnectionSettings.mode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ConnectionSettings.initialize();
    if (mounted) setState(() => _mode = ConnectionSettings.mode);
  }

  bool _isTunnelBusy(VpnStatus status) {
    return status == VpnStatus.connected ||
        status == VpnStatus.connecting ||
        status == VpnStatus.disconnecting;
  }

  Future<void> _changeMode(ConnectionMode? next) async {
    if (next == null || next == _mode) return;

    final vpn = context.read<VpnConnection>();
    if (_isTunnelBusy(vpn.status)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnect before changing connection mode.')),
      );
      return;
    }

    await ConnectionSettings.setMode(next);
    if (!mounted) return;
    setState(() => _mode = next);
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final proxyMode = _mode == ConnectionMode.proxy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text(
            'Connection mode',
            style: TextStyle(color: AppColors.textWhite, fontSize: 15),
          ),
          subtitle: Text(
            proxyMode
                ? 'Local SOCKS5/HTTP proxy. Traffic still exits through the same ReVolt VLESS/Reality server.'
                : 'TUN mode. Device traffic uses the Android VPN tunnel.',
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<ConnectionMode>(
              value: _mode,
              dropdownColor: AppColors.bgCard,
              onChanged: _changeMode,
              items: const [
                DropdownMenuItem(
                  value: ConnectionMode.tun,
                  child: Text('TUN'),
                ),
                DropdownMenuItem(
                  value: ConnectionMode.proxy,
                  child: Text('SOCKS5 / HTTP'),
                ),
              ],
            ),
          ),
        ),
        if (proxyMode)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'SOCKS5: 127.0.0.1:10807\nHTTP: 127.0.0.1:10808',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
