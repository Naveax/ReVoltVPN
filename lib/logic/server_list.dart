import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── lib/logic/server_list.dart ──────────────────────────────────────────────
// Server data model and ChangeNotifier — shared by StatusBar (shows current
// server name/flag) and SelectionScreen (lets user pick a server).
//
// Each server is defined by its tunnel IP/port. Reality credentials (public
// key, shortId) come from /session/status per session; only the transport
// parameters live in AppConfig.
//
// When multi-server ships:
//   - _all becomes a fetched list (from /api/servers or bundled config)
//   - SelectionScreen shows multiple rows
//   - select() triggers a disconnect/reconnect cycle if the tunnel is active

class ServerInfo {
  final String id;
  final String name;
  final String flagAsset;
  final String ip;
  final int port;

  const ServerInfo({
    required this.id,
    required this.name,
    required this.flagAsset,
    required this.ip,
    required this.port,
  });
}

class ServerList extends ChangeNotifier {
  static const _all = [
    ServerInfo(
      id: 'finland',
      name: 'Helsinki, Finland',
      flagAsset: 'assets/finland_flag_256.png',
      ip: '204.168.246.88',
      port: 443,
    ),
  ];

  int _selectedIndex = 0;

  List<ServerInfo> get all => _all;
  int get selectedIndex => _selectedIndex;
  ServerInfo get selected => _all[_selectedIndex];

  // Loads persisted selection from SharedPreferences.
  // Fire-and-forget — UI starts with default, updates when prefs load.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('selected_server_index') ?? 0;
    if (saved >= 0 && saved < _all.length && saved != _selectedIndex) {
      _selectedIndex = saved;
      notifyListeners();
    }
  }

  // Switches to a different server. Persists the choice.
  Future<void> select(int index) async {
    if (index == _selectedIndex || index < 0 || index >= _all.length) return;
    _selectedIndex = index;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('selected_server_index', index);
  }
}
