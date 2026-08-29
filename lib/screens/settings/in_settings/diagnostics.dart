import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/local_socks_tester.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class ConnectionDiagnosticsScreen extends StatefulWidget {
  const ConnectionDiagnosticsScreen({super.key});

  @override
  State<ConnectionDiagnosticsScreen> createState() =>
      _ConnectionDiagnosticsScreenState();
}

class _ConnectionDiagnosticsScreenState
    extends State<ConnectionDiagnosticsScreen> {
  LocalSocksTestResult? _socksTest;
  bool _testingSocks = false;

  Future<void> _runSocksTest() async {
    if (_testingSocks) return;
    setState(() => _testingSocks = true);
    final result = await LocalSocksTester.test();
    if (!mounted) return;
    setState(() {
      _testingSocks = false;
      _socksTest = result;
    });
  }

  String _buildReport(VpnConnection vpn) {
    final health = vpn.lastHealthLatencyMs == null
        ? 'unknown'
        : '${vpn.lastHealthLatencyMs} ms';
    final recovery = vpn.lastRecoveryReason ?? 'none';
    final socks = _socksTest == null
        ? 'not tested'
        : _socksTest!.ok
            ? 'OK${_socksTest!.latencyMs == null ? '' : ' (${_socksTest!.latencyMs} ms)'}'
            : 'failed: ${_socksTest!.message}';

    return <String>[
      'ReVoltVPN diagnostics',
      'Status: ${vpn.status.name}',
      'Message: ${vpn.statusMessage}',
      'Mode: ${vpn.activeMode.name}',
      'Resilience: ${vpn.activeResilienceMode.name}',
      'Transport profile: ${vpn.activeTransportProfile}',
      'Network: ${vpn.networkTransport}',
      'Network validated: ${vpn.networkValidated}',
      'API reachable: ${vpn.serverReachable}',
      'Runtime health: $health',
      'Reconnects: ${vpn.reconnectCount}',
      'Fallbacks: ${vpn.fallbackCount}',
      'Last recovery: $recovery',
      'App routing: ${ConnectionSettings.routingMode.name}',
      'Selected packages: ${ConnectionSettings.appPackages.length}',
      'Local SOCKS5: $socks',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        title: const Text('Connection diagnostics'),
      ),
      body: Consumer<VpnConnection>(
        builder: (context, vpn, _) {
          final rows = <MapEntry<String, String>>[
            MapEntry('Status', vpn.status.name),
            MapEntry('Connection mode', vpn.activeMode.name),
            MapEntry('Resilience', vpn.activeResilienceMode.name),
            MapEntry('Active profile', vpn.activeTransportProfile),
            MapEntry('Network', vpn.networkTransport),
            MapEntry('Validated', vpn.networkValidated ? 'yes' : 'no'),
            MapEntry('API', vpn.serverReachable ? 'reachable' : 'unreachable'),
            MapEntry(
              'Runtime health',
              vpn.lastHealthLatencyMs == null
                  ? 'unknown'
                  : '${vpn.lastHealthLatencyMs} ms',
            ),
            MapEntry('Reconnects', '${vpn.reconnectCount}'),
            MapEntry('Fallbacks', '${vpn.fallbackCount}'),
            MapEntry('Last recovery', vpn.lastRecoveryReason ?? 'none'),
            MapEntry('App routing', ConnectionSettings.routingMode.name),
            MapEntry(
              'Selected apps',
              '${ConnectionSettings.appPackages.length}',
            ),
          ];

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final row in rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    row.key,
                    style: const TextStyle(color: AppColors.textDim),
                  ),
                  trailing: Flexible(
                    child: Text(
                      row.value,
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: AppColors.textWhite),
                    ),
                  ),
                ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.network_check),
                title: const Text('Test Local SOCKS5'),
                subtitle: Text(
                  _socksTest == null
                      ? 'Tests 127.0.0.1:10807 and the ReVolt outbound.'
                      : _socksTest!.ok
                          ? 'OK${_socksTest!.latencyMs == null ? '' : ' · ${_socksTest!.latencyMs} ms'}'
                          : _socksTest!.message,
                ),
                trailing: _testingSocks
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _testingSocks ? null : _runSocksTest,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: _buildReport(vpn)),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Diagnostics copied.')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy diagnostics'),
              ),
            ],
          );
        },
      ),
    );
  }
}
