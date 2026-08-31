from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f'[3.3.14 polish] missing expected block: {label}')
    return text.replace(old, new, 1)


vpn_path = Path('lib/logic/vpn_connection.dart')
vpn = vpn_path.read_text()

vpn = replace_once(
    vpn,
    '  ConnectionMode _activeMode = ConnectionMode.auto;\n',
    '  ConnectionMode _activeMode = ConnectionMode.tun;\n',
    'default connection mode',
)

vpn = replace_once(
    vpn,
    "        notificationIconResourceName: 'notification_icon',\n",
    "        notificationIconResourceName: 'notification_status_icon',\n",
    'notification icon resource',
)

auto_label = """      case ConnectionMode.auto:
        return _selectedRoutingActive
            ? 'Auto · selected apps secured'
            : 'Auto · secured';
"""
if auto_label in vpn:
    vpn = vpn.replace(auto_label, '', 1)

old_comment = """    // Auto, TUN and transparent SOCKS5 all use one Android VpnService/TUN.
    // SOCKS5 remains available locally at 127.0.0.1:10807 behind that wrapper.
"""
new_comment = """    // TUN and SOCKS5 share the stable Android VpnService. SOCKS5 uses
    // an authenticated per-session local ingress instead of a fixed port.
"""
vpn = replace_once(vpn, old_comment, new_comment, 'runtime mode comment')

auto_start = """      ConnectionMode.auto => routingPlan.selectedOnly
          ? 'Auto · starting selected-app route…'
          : 'Auto · starting TUN…',
"""
if auto_start in vpn:
    vpn = vpn.replace(auto_start, '', 1)

auto_plan = """      case ConnectionMode.auto:
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan();
        }
        return _tunPlan(routingMode, selected);

"""
if auto_plan in vpn:
    vpn = vpn.replace(auto_plan, '', 1)

profile_anchor = """  String get activeTransportProfile =>
      _status == VpnStatus.connected || _status == VpnStatus.connecting
          ? 'server'
          : 'inactive';

"""
profile_replacement = profile_anchor + """  bool get canTestActiveLocalSocks =>
      _status == VpnStatus.connected &&
      _activeMode == ConnectionMode.proxy &&
      _lastSecureSocks != null;

  Future<LocalSocksTestResult> testActiveLocalSocks() async {
    final active = _lastSecureSocks;
    if (!canTestActiveLocalSocks || active == null) {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'No active authenticated SOCKS5 session.',
      );
    }

    return LocalSocksTester.test(
      host: '127.0.0.1',
      port: active.port,
      username: active.username,
      password: active.password,
    );
  }

"""
vpn = replace_once(
    vpn,
    profile_anchor,
    profile_replacement,
    'active SOCKS diagnostic bridge',
)

if 'ConnectionMode.auto' in vpn:
    raise SystemExit('[3.3.14 polish] ConnectionMode.auto remains in vpn_connection.dart')

vpn_path.write_text(vpn)


timer_path = Path('lib/logic/session_timer.dart')
timer = timer_path.read_text()

timer = replace_once(
    timer,
    "import 'package:flutter/foundation.dart';\n",
    "import 'package:flutter/foundation.dart';\nimport 'package:flutter/widgets.dart';\n",
    'widgets lifecycle import',
)

timer = replace_once(
    timer,
    'class SessionTimer extends ChangeNotifier {\n',
    'class SessionTimer extends ChangeNotifier with WidgetsBindingObserver {\n',
    'WidgetsBindingObserver mixin',
)

timer = replace_once(
    timer,
    '  int _remainingSeconds = 0;\n  int _usedBytes = 0;\n',
    '  int _remainingSeconds = 0;\n  int _remainingAtLastSync = 0;\n  int _usedBytes = 0;\n',
    'wall-clock session baseline',
)

timer = replace_once(
    timer,
    "  SessionTimer({required this.vpnConnection}) {\n    vpnConnection.addListener(_onVpnConnectionChanged);\n",
    "  SessionTimer({required this.vpnConnection}) {\n    WidgetsBinding.instance.addObserver(this);\n    vpnConnection.addListener(_onVpnConnectionChanged);\n",
    'lifecycle observer registration',
)

for label, old, new in [
    (
        'failure baseline reset',
        '    _remainingSeconds = 0;\n    _hasSyncedOnce = false;\n    _lastSuccessfulSyncAt = null;\n',
        '    _remainingSeconds = 0;\n    _remainingAtLastSync = 0;\n    _hasSyncedOnce = false;\n    _lastSuccessfulSyncAt = null;\n',
    ),
    (
        'start baseline reset',
        '    _remainingSeconds = 0;\n    _usedBytes = 0;\n',
        '    _remainingSeconds = 0;\n    _remainingAtLastSync = 0;\n    _usedBytes = 0;\n',
    ),
]:
    timer = replace_once(timer, old, new, label)

old_tick = """    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;
      }
    }
"""
new_tick = """    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      _reconcileElapsedTime();
    }
"""
timer = replace_once(timer, old_tick, new_tick, 'wall-clock ticking')

old_sync = """        _remainingSeconds = expiresValue.toInt();
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);

        final now = DateTime.now();
"""
new_sync = """        _remainingAtLastSync = expiresValue.toInt();
        _remainingSeconds = _remainingAtLastSync;
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);

        final now = DateTime.now();
"""
timer = replace_once(timer, old_sync, new_sync, 'successful sync baseline')

resume_anchor = """  void _resumeTicking() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    _syncWithHivemind();
    notifyListeners();
  }

"""
resume_replacement = """  void _reconcileElapsedTime() {
    final syncedAt = _lastSuccessfulSyncAt;
    if (!_hasSyncedOnce || syncedAt == null) return;

    final elapsed = DateTime.now().difference(syncedAt).inSeconds;
    _remainingSeconds = (_remainingAtLastSync - elapsed).clamp(0, 1 << 31);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _isDisconnecting) return;
    if (vpnConnection.status != VpnStatus.connected) return;

    _reconcileElapsedTime();
    if (!isRunning) {
      _resumeTicking();
      return;
    }

    unawaited(_syncWithHivemind());
    notifyListeners();
  }

  void _resumeTicking() {
    _reconcileElapsedTime();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    unawaited(_syncWithHivemind());
    notifyListeners();
  }

"""
timer = replace_once(timer, resume_anchor, resume_replacement, 'resume reconciliation')

timer = replace_once(
    timer,
    "  void dispose() {\n    vpnConnection.removeListener(_onVpnConnectionChanged);\n",
    "  void dispose() {\n    WidgetsBinding.instance.removeObserver(this);\n    vpnConnection.removeListener(_onVpnConnectionChanged);\n",
    'lifecycle observer cleanup',
)

timer_path.write_text(timer)

print('[3.3.14 polish] runtime and background lifecycle patches applied')
