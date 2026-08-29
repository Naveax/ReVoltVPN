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
  static const String localSocksAddress = '127.0.0.1:10807';

  ConnectionMode _mode = ConnectionSettings.mode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ConnectionSettings.initialize();
    if (mounted) {
      setState(() => _mode = ConnectionSettings.mode);
    }
  }

  bool _isTunnelBusy(VpnStatus status) {
    return status == VpnStatus.connected ||
        status == VpnStatus.connecting ||
        status == VpnStatus.disconnecting;
  }

  Future<bool> _setMode(ConnectionMode next) async {
    if (next == _mode) return true;

    final vpn = context.read<VpnConnection>();
    if (_isTunnelBusy(vpn.status)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Disconnect before changing connection mode.'),
        ),
      );
      return false;
    }

    await ConnectionSettings.setMode(next);
    if (!mounted) return false;

    setState(() => _mode = next);
    widget.onChanged?.call(next);
    return true;
  }

  Future<void> _changeMode(ConnectionMode? next) async {
    if (next == null) return;
    await _setMode(next);
  }

  Future<void> _selectLocalServer() async {
    final changed = await _setMode(ConnectionMode.proxy);
    if (!changed || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Server Local selected. Connect to start SOCKS5 on 127.0.0.1:10807.',
        ),
      ),
    );
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
                ? 'Local SOCKS5 mode. Traffic still exits through the same ReVolt VLESS/Reality server.'
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
                  child: Text('Local SOCKS5'),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: OutlinedButton.icon(
            onPressed: _selectLocalServer,
            icon: const Icon(Icons.dns_outlined),
            label: const Text('Server Local'),
          ),
        ),
        if (proxyMode)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'SOCKS5: $localSocksAddress\nUse the main Connect button to start the local proxy.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
