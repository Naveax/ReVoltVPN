import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:revoltvpn/logic/connection_settings.dart';

class BlockedAppsTile extends StatefulWidget {
  final bool enabled;

  const BlockedAppsTile({super.key, required this.enabled});

  @override
  State<BlockedAppsTile> createState() => _BlockedAppsTileState();
}

class _BlockedAppsTileState extends State<BlockedAppsTile> {
  int _selectedCount = ConnectionSettings.blockedApps.length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ConnectionSettings.initialize();
    if (mounted) {
      setState(() => _selectedCount = ConnectionSettings.blockedApps.length);
    }
  }

  Future<void> _openPicker() async {
    if (!widget.enabled) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _BlockedAppsPicker()),
    );

    if (mounted) {
      setState(() => _selectedCount = ConnectionSettings.blockedApps.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = !widget.enabled
        ? 'Available only in TUN mode.'
        : _selectedCount == 0
            ? 'No apps excluded.'
            : '$_selectedCount app${_selectedCount == 1 ? '' : 's'} bypass the VPN.';

    return ListTile(
      enabled: widget.enabled,
      onTap: _openPicker,
      title: const Text(
        'Exclude apps',
        style: TextStyle(color: AppColors.textWhite, fontSize: 15),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppColors.textDim, fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _InstalledApp {
  final String packageName;
  final String label;

  const _InstalledApp({required this.packageName, required this.label});
}

class _BlockedAppsPicker extends StatefulWidget {
  const _BlockedAppsPicker();

  @override
  State<_BlockedAppsPicker> createState() => _BlockedAppsPickerState();
}

class _BlockedAppsPickerState extends State<_BlockedAppsPicker> {
  static const MethodChannel _channel = MethodChannel('com.revoltvpn.app/apps');

  final Set<String> _selected = <String>{...ConnectionSettings.blockedApps};
  final TextEditingController _search = TextEditingController();

  List<_InstalledApp> _apps = const <_InstalledApp>[];
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
      final raw = await _channel.invokeListMethod<dynamic>('getLaunchableApps') ??
          const <dynamic>[];
      final apps = <_InstalledApp>[];

      for (final item in raw) {
        if (item is! Map) continue;
        final packageName = item['packageName'];
        final label = item['label'];
        if (packageName is! String || packageName.isEmpty) continue;
        apps.add(
          _InstalledApp(
            packageName: packageName,
            label: label is String && label.isNotEmpty ? label : packageName,
          ),
        );
      }

      apps.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load installed apps.';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    await ConnectionSettings.setBlockedApps(_selected);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final visibleApps = query.isEmpty
        ? _apps
        : _apps
            .where((app) =>
                app.label.toLowerCase().contains(query) ||
                app.packageName.toLowerCase().contains(query))
            .toList();

    return Scaffold(
      backgroundColor: AppColors.bgDeep,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        title: const Text('Exclude apps'),
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

  Widget _buildList(List<_InstalledApp> visibleApps) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: AppColors.textMuted)));
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
