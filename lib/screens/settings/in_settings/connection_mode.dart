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
    if (_testingLocalSocks) return;
    final vpn = context.read<VpnConnection>();

    if (vpn.status != VpnStatus.connected || !vpn.canTestActiveLocalSocks) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect with SOCKS5 first, then run the local test.'),
        ),
      );
      return;
    }

    setState(() => _testingLocalSocks = true);
    final result = await vpn.testActiveLocalSocks();
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
      case ConnectionMode.tun:
        return 'TUN: Android VPN routing for normal device traffic.';
      case ConnectionMode.proxy:
        return 'SOCKS5: authenticated per-session local gateway with transparent Android routing.';
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
                  value: ConnectionMode.tun,
                  child: Text('TUN'),
                ),
                DropdownMenuItem(
                  value: ConnectionMode.proxy,
                  child: Text('SOCKS5'),
                ),
              ],
            ),
          ),
        ),
        if (_mode == ConnectionMode.proxy) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'Secure Local SOCKS5 uses a private port and new credentials for every VPN session.',
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
              label: Text(
                _testingLocalSocks ? 'Testing…' : 'Test Local SOCKS',
              ),
            ),
          ),
          if (_lastSocksTest != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                _lastSocksTest!.ok
                    ? 'Last test: OK${_lastSocksTest!.latencyMs == null ? '' : ' · ${_lastSocksTest!.latencyMs} ms'}'
                    : 'Last test: Failed · ${_lastSocksTest!.message}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
