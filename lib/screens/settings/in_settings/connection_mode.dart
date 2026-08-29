import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/local_socks_tester.dart';
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
  bool _testingLocalSocks = false;
  LocalSocksTestResult? _lastSocksTest;

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

    setState(() {
      _mode = next;
      _lastSocksTest = null;
    });
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

  Future<void> _testLocalSocks() async {
    final vpn = context.read<VpnConnection>();
    if (vpn.status != VpnStatus.connected || vpn.activeMode != ConnectionMode.proxy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect with Local SOCKS5 first, then run the test.'),
        ),
      );
      return;
    }

    if (_testingLocalSocks) return;
    setState(() => _testingLocalSocks = true);

    final result = await LocalSocksTester.test();
    if (!mounted) return;

    setState(() {
      _testingLocalSocks = false;
      _lastSocksTest = result;
    });

    final latency = result.latencyMs == null ? '' : ' (${result.latencyMs} ms)';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${result.message}$latency')),
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
        if (proxyMode) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'SOCKS5: $localSocksAddress\nUse the main Connect button to start the local proxy.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: OutlinedButton.icon(
              onPressed: _testingLocalSocks ? null : _testLocalSocks,
              icon: _testingLocalSocks
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: Text(_testingLocalSocks ? 'Testing…' : 'Test Local SOCKS'),
            ),
          ),
          if (_lastSocksTest != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                _lastSocksTest!.ok
                    ? 'Last test: OK${_lastSocksTest!.latencyMs == null ? '' : ' · ${_lastSocksTest!.latencyMs} ms'}'
                    : 'Last test: Failed · ${_lastSocksTest!.message}',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
        ],
      ],
    );
  }
}
