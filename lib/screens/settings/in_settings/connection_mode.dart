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

  Future<void> _changeMode(ConnectionMode? next) async {
    if (next == null || next == _mode) return;

    final vpn = context.read<VpnConnection>();
    if (_isTunnelBusy(vpn.status)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Disconnect before changing connection mode.'),
        ),
      );
      return;
    }

    await ConnectionSettings.setMode(next);
    if (!mounted) return;

    setState(() {
      _mode = next;
      _lastSocksTest = null;
    });
    widget.onChanged?.call(next);
  }

  Future<void> _testLocalSocks() async {
    final vpn = context.read<VpnConnection>();
    if (vpn.status != VpnStatus.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect first, then test Local SOCKS5.')),
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

  String get _subtitle {
    switch (_mode) {
      case ConnectionMode.auto:
        return 'Auto: All/Exclude uses the stable TUN path. Selected only uses compatibility App Specific routing.';
      case ConnectionMode.tun:
        return 'TUN: Android VPN routing. Selected only keeps Android network helpers available for app compatibility.';
      case ConnectionMode.proxy:
        return 'SOCKS5: transparent gateway. Normal apps are routed automatically while $localSocksAddress stays available.';
      case ConnectionMode.ass:
        return 'ASS: selected apps are automatically routed through Local SOCKS5; Android network helpers stay available.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text(
            'Connection mode',
            style: TextStyle(color: AppColors.textWhite, fontSize: 15),
          ),
          subtitle: Text(
            _subtitle,
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<ConnectionMode>(
              value: _mode,
              dropdownColor: AppColors.bgCard,
              onChanged: _changeMode,
              items: const [
                DropdownMenuItem(
                  value: ConnectionMode.auto,
                  child: Text('Auto'),
                ),
                DropdownMenuItem(
                  value: ConnectionMode.tun,
                  child: Text('TUN'),
                ),
                DropdownMenuItem(
                  value: ConnectionMode.proxy,
                  child: Text('SOCKS5'),
                ),
                DropdownMenuItem(
                  value: ConnectionMode.ass,
                  child: Text('App Specific (ASS)'),
                ),
              ],
            ),
          ),
        ),
        if (_mode == ConnectionMode.proxy)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Transparent routing + SOCKS5: 127.0.0.1:10807 · HTTP: 127.0.0.1:10808',
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
    );
  }
}
