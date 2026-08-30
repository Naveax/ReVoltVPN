import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/installed_apps_service.dart';
import 'package:revoltvpn/logic/local_socks_tester.dart';
import 'package:revoltvpn/logic/network_monitor.dart';

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class _RoutingPlan {
  final List<String>? blockedApps;
  final bool selectedOnly;
  final bool verifyLocalSocks;

  const _RoutingPlan({
    required this.blockedApps,
    this.selectedOnly = false,
    this.verifyLocalSocks = false,
  });
}

class VpnConnection extends ChangeNotifier {
  static const int _maxExtremeRecoveryAttempts = 2;

  bool _cancelled = false;
  VpnStatus _status = VpnStatus.disconnected;
  VpnStatus get status => _status;

  String _statusMessage = 'Tap to connect';
  String get statusMessage => _statusMessage;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool _isStartupRestoration = false;
  bool get isStartupRestoration => _isStartupRestoration;

  bool _serverReachable = false;
  bool get serverReachable => _serverReachable;

  ConnectionMode _activeMode = ConnectionMode.auto;
  ConnectionMode get activeMode => _activeMode;

  ResilienceMode _activeResilienceMode = ResilienceMode.standard;
  ResilienceMode get activeResilienceMode => _activeResilienceMode;

  bool _selectedRoutingActive = false;
  bool get selectedRoutingActive => _selectedRoutingActive;

  String _networkTransport = 'unknown';
  String get networkTransport => _networkTransport;

  bool _networkValidated = false;
  bool get networkValidated => _networkValidated;

  int? _lastHealthLatencyMs;
  int? get lastHealthLatencyMs => _lastHealthLatencyMs;

  int _reconnectCount = 0;
  int get reconnectCount => _reconnectCount;

  int get fallbackCount => 0;

  String? _lastRecoveryReason;
  String? get lastRecoveryReason => _lastRecoveryReason;

  String get activeRoutingDescription {
    if (_activeMode == ConnectionMode.proxy) {
      if (_selectedRoutingActive) return 'SOCKS5 · selected apps';
      if (_lastBlockedApps?.isNotEmpty == true) return 'SOCKS5 · exclude apps';
      return 'SOCKS5 · all apps';
    }
    if (_selectedRoutingActive) return 'Selected apps';
    if (_lastBlockedApps?.isNotEmpty == true) return 'Exclude apps';
    return 'All apps';
  }

  String get activeTransportProfile =>
      _status == VpnStatus.connected || _status == VpnStatus.connecting
          ? 'server'
          : 'inactive';

  Timer? _healthTimer;
  Timer? _restartTimer;
  StreamSubscription<NetworkSnapshot>? _networkSubscription;

  String? _lastBaseConfig;
  String _lastRemark = 'Revolt VPN';
  List<String>? _lastBlockedApps;
  bool _lastSelectedOnly = false;
  bool _lastVerifyLocalSocks = false;
  bool _restartInProgress = false;
  bool _userDisconnecting = false;

  late final FlutterVless _vless;
  bool _initialized = false;
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  VpnConnection() {
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;
    _init();
  }

  Future<void> _init() async {
    try {
      await _startEngine();
    } catch (e) {
      debugPrint('[VPN] Engine init failed: $e');
    } finally {
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  Future<void> _startEngine() async {
    if (kIsWeb) return;

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;

    _vless = FlutterVless(
      onStatusChanged: (status) {
        debugPrint(
          '[VPN] Status: state=${status.state} '
          'connection=${status.connectionState.name}',
        );
        _mapStatus(status);
      },
    );

    try {
      await _vless.initializeVless(
        providerBundleIdentifier: 'com.paladinvpn.app',
        notificationIconResourceType: 'drawable',
        notificationIconResourceName: 'notification_icon',
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[VPN] VLESS init error (expected on emulator): $e');
    }

    _networkSubscription = NetworkMonitor.changes.listen(
      (snapshot) {
        // ConnectivityManager is informational only. Restarting from every
        // callback caused the old VPN-created-network reconnect loop.
        _networkTransport = snapshot.transport;
        _networkValidated = snapshot.validated;
        notifyListeners();
      },
      onError: (Object error) {
        debugPrint('[VPN] Network monitor error: $error');
      },
    );

    unawaited(_checkHealth());
    _healthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_checkHealth());
    });

    try {
      final coreVersion = await _vless.getCoreVersion();
      debugPrint('[VPN] Xray core version: $coreVersion');

      final delay = await _vless.getConnectedServerDelay();
      if (delay > 0) {
        _lastHealthLatencyMs = delay;
        _isStartupRestoration = true;
        _restoreRoutingPresentationFromSettings();
        _setStatus(VpnStatus.connected, _connectedLabel);
      }
    } catch (_) {}
  }

  void _restoreRoutingPresentationFromSettings() {
    final routingMode = ConnectionSettings.routingMode;
    final packages = ConnectionSettings.appPackages;

    _lastBlockedApps = null;
    _lastSelectedOnly = false;
    _lastVerifyLocalSocks = _activeMode == ConnectionMode.proxy;
    _selectedRoutingActive = false;

    if (routingMode == AppRoutingMode.selected) {
      _lastSelectedOnly = packages.isNotEmpty;
      _selectedRoutingActive = packages.isNotEmpty;
      return;
    }

    if (routingMode == AppRoutingMode.exclude && packages.isNotEmpty) {
      _lastBlockedApps = List.of(packages);
    }
  }

  String get _connectedLabel {
    switch (_activeMode) {
      case ConnectionMode.auto:
        return _selectedRoutingActive
            ? 'Auto · selected apps secured'
            : 'Auto · secured';
      case ConnectionMode.proxy:
        return _selectedRoutingActive
            ? 'SOCKS5 · selected apps secured'
            : 'SOCKS5 gateway active';
      case ConnectionMode.tun:
        return _selectedRoutingActive ? 'Selected apps secured' : 'Secured';
    }
  }

  void _mapStatus(VlessStatus status) {
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        _setStatus(VpnStatus.connected, _connectedLabel);
        break;

      case VlessConnectionState.disconnected:
        // Repeated DISCONNECTED broadcasts during an Extreme recovery debounce
        // must not clear the config snapshot the pending recovery needs.
        if (_restartInProgress || (_restartTimer?.isActive ?? false)) return;

        final canRecover = !_userDisconnecting &&
            _activeResilienceMode == ResilienceMode.extreme &&
            _lastBaseConfig != null &&
            _status == VpnStatus.connected;
        if (canRecover) {
          _scheduleRuntimeRestart('Runtime disconnected');
          return;
        }

        _clearRuntimeSnapshot();
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;

      case VlessConnectionState.connecting:
        if (!_restartInProgress) {
          _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        }
        break;

      case VlessConnectionState.disconnecting:
        _isStartupRestoration = false;
        if (!_restartInProgress) {
          _setStatus(VpnStatus.disconnecting, 'Tearing down…');
        }
        break;

      case VlessConnectionState.unknown:
        if (_status != VpnStatus.connected &&
            _status != VpnStatus.disconnected &&
            !_restartInProgress) {
          _setStatus(VpnStatus.error, 'Connection failed');
        }
        break;
    }
  }

  Future<bool> connect({bool skipAdBypass = false}) async {
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      return false;
    }

    _cancelled = false;
    _userDisconnecting = false;
    _restartTimer?.cancel();
    _reconnectCount = 0;
    _lastRecoveryReason = null;
    _lastHealthLatencyMs = null;
    _selectedRoutingActive = false;

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;
    _activeResilienceMode = ConnectionSettings.resilienceMode;

    late final _RoutingPlan routingPlan;
    try {
      routingPlan = await _resolveRoutingPlan();
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Bad state: ', '');
      _setStatus(VpnStatus.error, 'App routing error');
      return false;
    }

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    // Auto, TUN and transparent SOCKS5 all use one Android VpnService/TUN.
    // SOCKS5 remains available locally at 127.0.0.1:10807 behind that wrapper.
    if (!kIsWeb) {
      final ok = await _vless.requestPermission();
      if (!ok) {
        _errorMessage = 'VPN permission denied.';
        _setStatus(VpnStatus.error, 'Permission required');
        return false;
      }
    }

    final startingMessage = switch (_activeMode) {
      ConnectionMode.auto => routingPlan.selectedOnly
          ? 'Auto · starting selected-app route…'
          : 'Auto · starting TUN…',
      ConnectionMode.tun => routingPlan.selectedOnly
          ? 'Starting selected-app tunnel…'
          : 'Establishing secure channel…',
      ConnectionMode.proxy => routingPlan.selectedOnly
          ? 'SOCKS5 · starting selected-app gateway…'
          : 'Starting transparent SOCKS5 gateway…',
    };
    _setStatus(VpnStatus.connecting, startingMessage);
    _errorMessage = null;

    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    _setStatus(VpnStatus.connecting, 'Fetching config…');

    String realUrl;
    try {
      realUrl = await HivemindService.fetchConfigDirectly(
        skipAdBypass: skipAdBypass,
        onAttempt: (attempt, total) {
          _setStatus(
            VpnStatus.connecting,
            'Contacting server ($attempt/$total)…',
          );
        },
      );
    } catch (e) {
      debugPrint('[VPN] Config fetch error: $e');
      final raw = e.toString().replaceAll('Exception: ', '');
      if (raw.contains('Cancelled')) return false;
      if (raw.contains('timed out') || raw.contains('Session not activated')) {
        _errorMessage =
            'The server did not respond in time.\nCheck your connection and try again.';
        _setStatus(VpnStatus.error, 'Server unreachable');
      } else {
        _errorMessage = raw;
        _setStatus(VpnStatus.error, 'Config fetch error');
      }
      return false;
    }

    if (_cancelled) {
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      return false;
    }

    _setStatus(VpnStatus.connecting, 'Starting secure route…');

    try {
      final parsed = FlutterVless.parse(realUrl);
      final baseConfig = parsed.getFullConfiguration();
      final remark = parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN';

      // Set this before the native callback can report CONNECTED so the first
      // visible label already reflects Selected only accurately.
      _selectedRoutingActive = routingPlan.selectedOnly;

      await _startRuntime(
        config: baseConfig,
        remark: remark,
        blockedApps: routingPlan.blockedApps,
      );

      _setStatus(VpnStatus.connecting, 'Waiting for VPN interface…');
      if (!await _waitForNativeConnected()) {
        throw StateError('VPN runtime did not report CONNECTED');
      }

      if (routingPlan.verifyLocalSocks) {
        _setStatus(VpnStatus.connecting, 'Checking Local SOCKS5…');
        if (!await _waitForLocalSocksListener()) {
          throw StateError('Local SOCKS5 listener did not become ready');
        }
      }

      _lastBaseConfig = baseConfig;
      _lastRemark = remark;
      _lastBlockedApps = routingPlan.blockedApps == null
          ? null
          : List.of(routingPlan.blockedApps!);
      _lastSelectedOnly = routingPlan.selectedOnly;
      _lastVerifyLocalSocks = routingPlan.verifyLocalSocks;
      _selectedRoutingActive = routingPlan.selectedOnly;
    } catch (e) {
      debugPrint('[VPN] Tunnel start error: $e');
      await _stopRuntime();
      _clearRuntimeSnapshot();
      _errorMessage = _activeMode == ConnectionMode.proxy
          ? 'SOCKS5 gateway failed to start.\nTry reconnecting.'
          : 'Connection failed to start.\nTry reconnecting.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    }

    _setStatus(VpnStatus.connected, _connectedLabel);
    return true;
  }

  Future<_RoutingPlan> _resolveRoutingPlan() async {
    final routingMode = ConnectionSettings.routingMode;
    final selected = ConnectionSettings.appPackages;

    switch (_activeMode) {
      case ConnectionMode.auto:
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan();
        }
        return _tunPlan(routingMode, selected);

      case ConnectionMode.tun:
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan();
        }
        return _tunPlan(routingMode, selected);

      case ConnectionMode.proxy:
        // SOCKS5 is a transparent gateway: Android captures ordinary app
        // traffic into the same local SOCKS ingress used by Xray/tun2socks.
        if (routingMode == AppRoutingMode.selected) {
          return _selectedCompatibilityPlan(verifyLocalSocks: true);
        }
        return _tunPlan(
          routingMode,
          selected,
          verifyLocalSocks: true,
        );
    }
  }

  _RoutingPlan _tunPlan(
    AppRoutingMode routingMode,
    List<String> selected, {
    bool verifyLocalSocks = false,
  }) {
    if (routingMode == AppRoutingMode.exclude) {
      return _RoutingPlan(
        blockedApps: selected.isEmpty ? null : selected,
        verifyLocalSocks: verifyLocalSocks,
      );
    }

    return _RoutingPlan(
      blockedApps: null,
      verifyLocalSocks: verifyLocalSocks,
    );
  }

  Future<_RoutingPlan> _selectedCompatibilityPlan({
    bool verifyLocalSocks = false,
  }) async {
    final selected = ConnectionSettings.appPackages.toSet();
    if (selected.isEmpty) {
      throw StateError('Select at least one app.');
    }

    final apps = await InstalledAppsService.loadLaunchableApps();
    final availableSelected = apps
        .where((app) => selected.contains(app.packageName))
        .map((app) => app.packageName)
        .toSet();

    if (availableSelected.isEmpty) {
      throw StateError('None of the selected apps are installed.');
    }

    // Compatibility Selected only uses the plugin's proven blocklist path:
    // every other launchable user app bypasses the VPN, while Android system
    // helpers (DNS resolver, Play Services, network stack, etc.) remain able to
    // support selected apps such as Discord.
    final blocked = apps
        .map((app) => app.packageName)
        .where((packageName) => !availableSelected.contains(packageName))
        .toSet()
        .toList()
      ..sort();

    return _RoutingPlan(
      blockedApps: blocked.isEmpty ? null : blocked,
      selectedOnly: true,
      verifyLocalSocks: verifyLocalSocks,
    );
  }

  Future<void> _startRuntime({
    required String config,
    required String remark,
    required List<String>? blockedApps,
  }) async {
    await _vless.startVless(
      remark: remark,
      config: config,
      blockedApps: blockedApps,
      proxyOnly: false,
    );
  }

  Future<bool> _waitForLocalSocksListener() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await LocalSocksTester.testListener();
      if (result.ok) {
        _lastHealthLatencyMs = result.latencyMs;
        notifyListeners();
        return true;
      }
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
    return false;
  }

  Future<bool> _waitForNativeConnected() async {
    // startVless() queues the Android foreground service. Wait for the native
    // service/core broadcast rather than treating MethodChannel completion as
    // proof that a TUN interface was established.
    for (var attempt = 0; attempt < 24; attempt++) {
      if (_status == VpnStatus.connected) return true;
      if (_status == VpnStatus.error) return false;
      if (_cancelled || _userDisconnecting) return false;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return _status == VpnStatus.connected;
  }

  void _scheduleRuntimeRestart(String reason) {
    if (_activeResilienceMode != ResilienceMode.extreme ||
        _restartInProgress ||
        _userDisconnecting ||
        _lastBaseConfig == null ||
        (_restartTimer?.isActive ?? false)) {
      return;
    }

    _lastRecoveryReason = reason;
    _setStatus(VpnStatus.connecting, 'Reconnecting…');
    _restartTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_restartActiveRuntime(reason));
    });
  }

  Future<void> _restartActiveRuntime(String reason) async {
    if (_restartInProgress || _userDisconnecting || _lastBaseConfig == null) {
      return;
    }

    _restartInProgress = true;
    Object? lastError;

    try {
      for (var attempt = 1;
          attempt <= _maxExtremeRecoveryAttempts;
          attempt++) {
        if (_userDisconnecting || _lastBaseConfig == null) return;

        try {
          debugPrint(
            '[VPN] Extreme recovery attempt '
            '$attempt/$_maxExtremeRecoveryAttempts: $reason',
          );

          await _stopRuntime();
          if (_userDisconnecting) return;

          await Future.delayed(
            Duration(milliseconds: attempt == 1 ? 600 : 900),
          );
          if (_userDisconnecting || _lastBaseConfig == null) return;

          await _startRuntime(
            config: _lastBaseConfig!,
            remark: _lastRemark,
            blockedApps: _lastBlockedApps,
          );

          if (!await _waitForNativeConnected()) {
            throw StateError('VPN runtime did not recover');
          }
          if (_lastVerifyLocalSocks &&
              !(await _waitForLocalSocksListener())) {
            throw StateError('Local SOCKS5 listener did not recover');
          }

          if (_userDisconnecting) return;

          _reconnectCount++;
          _lastRecoveryReason = reason;
          _selectedRoutingActive = _lastSelectedOnly;
          _errorMessage = null;
          _setStatus(VpnStatus.connected, _connectedLabel);
          return;
        } catch (e) {
          lastError = e;
          debugPrint(
            '[VPN] Extreme recovery attempt '
            '$attempt/$_maxExtremeRecoveryAttempts failed: $e',
          );
          await _stopRuntime();
          if (_userDisconnecting) return;

          if (attempt < _maxExtremeRecoveryAttempts) {
            _setStatus(
              VpnStatus.connecting,
              'Reconnecting… (${attempt + 1}/$_maxExtremeRecoveryAttempts)',
            );
            await Future.delayed(const Duration(milliseconds: 700));
          }
        }
      }

      if (_userDisconnecting) return;

      debugPrint('[VPN] Extreme recovery exhausted: $lastError');
      _clearRuntimeSnapshot();
      _errorMessage = 'Could not restore the connection.';
      _setStatus(VpnStatus.error, 'Reconnect failed');
    } finally {
      _restartInProgress = false;
    }
  }

  Future<void> _stopRuntime() async {
    try {
      await _vless.stopVless().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _cancelled = true;
    _userDisconnecting = true;
    _restartTimer?.cancel();
    HivemindService.cancel();

    if (_status == VpnStatus.disconnected ||
        _status == VpnStatus.disconnecting) {
      _clearRuntimeSnapshot();
      _userDisconnecting = false;
      return;
    }

    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      _userDisconnecting = false;
      return;
    }

    bool timedOut = false;
    try {
      await _vless.stopVless().timeout(
            const Duration(seconds: 5),
            onTimeout: () => timedOut = true,
          );
    } catch (e) {
      debugPrint('[VPN] VLESS stop error: $e');
      _errorMessage = 'VPN shutdown error.\nPlease restart the app.';
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    if (timedOut) {
      debugPrint('[VPN] stopVless() timed out after 5 s.');
      _errorMessage = 'VPN did not shut down cleanly.\nPlease restart the app.';
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.error, 'Shutdown failed');
      _userDisconnecting = false;
      return;
    }

    _errorMessage = null;
    _clearRuntimeSnapshot();
    _setStatus(VpnStatus.disconnected, 'Tap to connect');
    _userDisconnecting = false;
  }

  void _clearRuntimeSnapshot() {
    _lastBaseConfig = null;
    _lastBlockedApps = null;
    _lastSelectedOnly = false;
    _lastVerifyLocalSocks = false;
    _selectedRoutingActive = false;
    _lastHealthLatencyMs = null;
    _isStartupRestoration = false;
  }

  void _setStatus(VpnStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  Future<void> _checkHealth() async {
    _serverReachable = await HivemindService.checkHealth();
    notifyListeners();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _restartTimer?.cancel();
    _networkSubscription?.cancel();
    if (_status == VpnStatus.connected || _status == VpnStatus.connecting) {
      try {
        _vless.stopVless();
      } catch (_) {}
    }
    super.dispose();
  }
}
