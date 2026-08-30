import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/installed_apps_service.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class AppRoutingTile extends StatefulWidget {
  final ConnectionMode connectionMode;

  const AppRoutingTile({super.key, required this.connectionMode});

  @override
  State<AppRoutingTile> createState() => _AppRoutingTileState();
}

class _AppRoutingTileState extends State<AppRoutingTile> {
  AppRoutingMode _mode = ConnectionSettings.routingMode;
  int _selectedCount = ConnectionSettings.appPackages.length;

  bool get _assMode => widget.connectionMode == ConnectionMode.ass;
  bool get _proxyMode => widget.connectionMode == ConnectionMode.proxy;
  bool get _autoMode => widget.connectionMode == ConnectionMode.auto;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ConnectionSettings.initialize();
    if (!mounted) return;
    setState(() {
      _mode = ConnectionSettings.routingMode;
      _selectedCount = ConnectionSettings.appPackages.length;
    });
  }

  bool _vpnBusy() {
    final status = context.read<VpnConnection>().status;
    return status == VpnStatus.connected ||
        status == VpnStatus.connecting ||
        status == VpnStatus.disconnecting;
  }

  void _showDisconnectFirst() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Disconnect before changing app routing.')),
    );
  }

  Future<void> _changeMode(AppRoutingMode? next) async {
    // SOCKS5 is deliberately an unrestricted transparent all-app mode.
    // Keep the saved policy for TUN/ASS/Auto without applying a limiter here.
    if (_proxyMode || _assMode || next == null || next == _mode) return;
    if (_vpnBusy()) {
      _showDisconnectFirst();
      return;
    }

    await ConnectionSettings.setRoutingMode(next);
    if (mounted) setState(() => _mode = next);
  }

  Future<void> _openPicker() async {
    if (_proxyMode || (!_assMode && _mode == AppRoutingMode.all)) return;
    if (_vpnBusy()) {
      _showDisconnectFirst();
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _AppPicker(
          mode: _assMode ? AppRoutingMode.selected : _mode,
        ),
      ),
    );

    if (mounted) {
      setState(() => _selectedCount = ConnectionSettings.appPackages.length);
    }
  }

  String get _subtitle {
    if (_assMode) {
      return _selectedCount == 0
          ? 'Choose at least one app. ASS keeps Android helper services available for compatibility.'
          : '$_selectedCount selected app${_selectedCount == 1 ? '' : 's'} use ReVolt; unrelated user apps bypass it.';
    }

    if (_proxyMode) {
      return 'SOCKS5 is transparent all-app mode. No app limiter is applied; saved choices remain available for other modes.';
    }

    if (_autoMode) {
      switch (_mode) {
        case AppRoutingMode.all:
          return 'Auto uses normal TUN routing for all apps.';
        case AppRoutingMode.exclude:
          return _selectedCount == 0
              ? 'Auto uses TUN. No apps are excluded.'
              : 'Auto uses TUN and $_selectedCount app${_selectedCount == 1 ? '' : 's'} bypass it.';
        case AppRoutingMode.selected:
          return _selectedCount == 0
              ? 'Choose apps. Auto will use compatibility selected-app routing.'
              : 'Auto routes $_selectedCount selected app${_selectedCount == 1 ? '' : 's'} through ReVolt while keeping required system helpers available.';
      }
    }

    switch (_mode) {
      case AppRoutingMode.all:
        return 'All apps use the VPN.';
      case AppRoutingMode.exclude:
        return _selectedCount == 0
            ? 'No apps excluded.'
            : '$_selectedCount app${_selectedCount == 1 ? '' : 's'} bypass the VPN.';
      case AppRoutingMode.selected:
        return _selectedCount == 0
            ? 'Choose at least one routed app.'
            : '$_selectedCount selected app${_selectedCount == 1 ? '' : 's'} use the VPN; Android helper services remain compatible.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final showPicker = !_proxyMode && (_assMode || _mode != AppRoutingMode.all);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text(
            'App routing',
            style: TextStyle(color: AppColors.textWhite, fontSize: 15),
          ),
          subtitle: Text(
            _subtitle,
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
          trailing: _proxyMode
              ? const Text(
                  'All apps',
                  style: TextStyle(color: AppColors.textWhite, fontSize: 12),
                )
              : _assMode
                  ? const Text(
                      'Selected apps',
                      style: TextStyle(color: AppColors.textWhite, fontSize: 12),
                    )
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<AppRoutingMode>(
                        value: _mode,
                        dropdownColor: AppColors.bgCard,
                        onChanged: _changeMode,
                        items: const [
                          DropdownMenuItem(
                            value: AppRoutingMode.all,
                            child: Text('All apps'),
                          ),
                          DropdownMenuItem(
                            value: AppRoutingMode.exclude,
                            child: Text('Exclude apps'),
                          ),
                          DropdownMenuItem(
                            value: AppRoutingMode.selected,
                            child: Text('Selected apps'),
                          ),
                        ],
                      ),
                    ),
        ),
        if (showPicker)
          ListTile(
            onTap: _openPicker,
            leading: const Icon(Icons.apps),
            title: Text(
              _assMode || _mode == AppRoutingMode.selected
                  ? 'Choose routed apps'
                  : 'Choose excluded apps',
            ),
            subtitle: Text(
              _assMode || _mode == AppRoutingMode.selected
                  ? 'Selected user apps use ReVolt; required Android helper traffic is kept compatible.'
                  : 'Selected Android package IDs bypass ReVolt.',
            ),
            trailing: const Icon(Icons.chevron_right),
          ),
      ],
    );
  }
}

class _AppPicker extends StatefulWidget {
  final AppRoutingMode mode;

  const _AppPicker({required this.mode});

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  final Set<String> _selected = <String>{...ConnectionSettings.appPackages};
  final TextEditingController _search = TextEditingController();

  List<InstalledApp> _apps = const <InstalledApp>[];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    try {
      final apps = await InstalledAppsService.loadLaunchableApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load installed apps.';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    await ConnectionSettings.setAppPackages(_selected);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final visibleApps = query.isEmpty
        ? _apps
        : _apps
            .where(
              (app) =>
                  app.label.toLowerCase().contains(query) ||
                  app.packageName.toLowerCase().contains(query),
            )
            .toList();

    final title = widget.mode == AppRoutingMode.exclude
        ? 'Exclude apps'
        : 'Selected routed apps';

    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        title: Text(title),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search apps',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(child: _buildList(visibleApps)),
        ],
      ),
    );
  }

  Widget _buildList(List<InstalledApp> visibleApps) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: AppColors.textMuted)),
      );
    }
    if (visibleApps.isEmpty) {
      return const Center(
        child: Text('No apps found.', style: TextStyle(color: AppColors.textMuted)),
      );
    }

    return ListView.builder(
      itemCount: visibleApps.length,
      itemBuilder: (context, index) {
        final app = visibleApps[index];
        final selected = _selected.contains(app.packageName);

        return CheckboxListTile(
          value: selected,
          onChanged: (value) {
            setState(() {
              if (value == true) {
                _selected.add(app.packageName);
              } else {
                _selected.remove(app.packageName);
              }
            });
          },
          secondary: app.iconPng == null
              ? const CircleAvatar(child: Icon(Icons.android, size: 20))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    app.iconPng!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
          title: Text(app.label),
          subtitle: Text(
            app.packageName,
            style: const TextStyle(color: AppColors.textDim, fontSize: 11),
          ),
        );
      },
    );
  }
}
