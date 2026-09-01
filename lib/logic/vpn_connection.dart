import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/local_socks_tester.dart';
import 'package:revoltvpn/logic/network_monitor.dart';
import 'package:revoltvpn/logic/power_settings.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

class VpnConnection extends ChangeNotifier {
  bool _cancelled = false;
  VpnStatus _status = VpnStatus.disconnected;
  VpnStatus get status => _status;

  String _statusMessage = 'Tap to connect';
  String get statusMessage => _statusMessage;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// True when the UI attached to a tunnel that was already running, rather
  /// than starting one itself. The session timer uses this to resume ticking.
  bool _adoptedRunningRuntime = false;
  bool get adoptedRunningRuntime => _adoptedRunningRuntime;

  bool _serverReachable = false;
  bool get serverReachable => _serverReachable;

  ConnectionMode _activeMode = ConnectionMode.tun;
  ConnectionMode get activeMode => _activeMode;

  String _networkTransport = 'unknown';
  String get networkTransport => _networkTransport;

  SecureSocksSession? get activeSocksSession => _lastSecureSocks;

  bool get canTestActiveLocalSocks =>
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

  Timer? _healthTimer;
  StreamSubscription<NetworkSnapshot>? _networkSubscription;

  SecureSocksSession? _lastSecureSocks;
  bool _userDisconnecting = false;

  late final FlutterVless _vless;
  bool _initialized = false;
  final Completer<void> _readyCompleter = Completer<void>();
  Future<void> get ready => _readyCompleter.future;

  VpnConnection() {
    _activeMode = ConnectionSettings.mode;
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
    } catch (_) {}

    await _adoptRunningRuntime();
  }

  /// Reflect a tunnel that is already up when the UI starts.
  ///
  /// This asks the OS whether our VPN service process is alive, rather than
  /// probing a local SOCKS port. The old probe called getConnectedServerDelay(),
  /// which reads AppConfigs.V2RAY_CONFIG?.LOCAL_SOCKS5_PORT ?: 10807 — but
  /// AppConfigs lives in the VPN's own process, so from here it is always null
  /// and the port always fell back to 10807. That was correct only while the
  /// SOCKS port was fixed; per-session ephemeral ports made it permanently
  /// wrong, so the app reported "connected" against a dead tunnel.
  Future<void> _adoptRunningRuntime() async {
    if (kIsWeb) return;
    try {
      final state = await PowerSettings.runtimeState();
      if (state.aliveFor(tunMode: _activeMode == ConnectionMode.tun)) {
        _adoptedRunningRuntime = true;
        _setStatus(VpnStatus.connected, _connectedLabel);
      }
    } catch (e) {
      debugPrint('[VPN] Runtime liveness check failed: $e');
    }
  }

  String get _connectedLabel {
    switch (_activeMode) {
      case ConnectionMode.proxy:
        return 'SOCKS5 gateway active';
      case ConnectionMode.tun:
        return 'Secured';
    }
  }

  void _mapStatus(VlessStatus status) {
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        _setStatus(VpnStatus.connected, _connectedLabel);
        break;

      case VlessConnectionState.disconnected:
        _clearRuntimeSnapshot();
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;

      case VlessConnectionState.connecting:
        _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        break;

      case VlessConnectionState.disconnecting:
        _setStatus(VpnStatus.disconnecting, 'Tearing down…');
        break;

      case VlessConnectionState.unknown:
        if (_status != VpnStatus.connected &&
            _status != VpnStatus.disconnected) {
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

    await ConnectionSettings.initialize();
    _activeMode = ConnectionSettings.mode;

    if (!kIsWeb && !_initialized) {
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    // TUN needs the Android VPN permission; SOCKS5 proxy mode runs a local
    // authenticated proxy without a VpnService, so no VPN permission is needed.
    if (!kIsWeb && _activeMode == ConnectionMode.tun) {
      final ok = await _vless.requestPermission();
      if (!ok) {
        _errorMessage = 'VPN permission denied.';
        _setStatus(VpnStatus.error, 'Permission required');
        return false;
      }
    }

    final startingMessage = switch (_activeMode) {
      ConnectionMode.tun => 'Establishing secure channel…',
      ConnectionMode.proxy => 'Starting local SOCKS5 proxy…',
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
      final secureSocks = await SecureSocksSession.create(baseConfig);
      final verifyLocalSocks = _activeMode == ConnectionMode.proxy;

      await _startRuntime(
        config: secureSocks.configJson,
        remark: remark,
        proxyOnly: verifyLocalSocks,
      );

      _setStatus(
        VpnStatus.connecting,
        verifyLocalSocks ? 'Waiting for local SOCKS5…' : 'Waiting for VPN interface…',
      );
      if (!await _waitForNativeConnected()) {
        throw StateError('VPN runtime did not report CONNECTED');
      }

      if (verifyLocalSocks) {
        _setStatus(VpnStatus.connecting, 'Checking Local SOCKS5…');
        if (!await _waitForLocalSocksListener(secureSocks)) {
          throw StateError('Local SOCKS5 listener did not become ready');
        }
      }

      _lastSecureSocks = secureSocks;
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

  Future<void> _startRuntime({
    required String config,
    required String remark,
    required bool proxyOnly,
  }) async {
    await _vless.startVless(
      remark: remark,
      config: config,
      proxyOnly: proxyOnly,
    );
  }

  Future<bool> _waitForLocalSocksListener([
    SecureSocksSession? session,
  ]) async {
    final active = session ?? _lastSecureSocks;
    if (active == null) return false;

    for (var attempt = 0; attempt < 4; attempt++) {
      final result = await LocalSocksTester.testListener(
        host: '127.0.0.1',
        port: active.port,
        username: active.username,
        password: active.password,
      );
      if (result.ok) {
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

  Future<void> _stopRuntime() async {
    try {
      await _vless.stopVless().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> disconnect() async {
    _cancelled = true;
    _userDisconnecting = true;
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
    _lastSecureSocks = null;
    _adoptedRunningRuntime = false;
  }

  void _setStatus(VpnStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  Future<void> _checkHealth() async {
    // A live tunnel already proves reachability; only probe while disconnected
    // so we don't add direct /health traffic while the VPN is active.
    if (_status == VpnStatus.connected) return;
    _serverReachable = await HivemindService.checkHealth();
    notifyListeners();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _networkSubscription?.cancel();
    // Provider/UI disposal is not a user disconnect command. Keeping teardown
    // in disconnect() prevents lifecycle churn from silently dropping the VPN.
    super.dispose();
  }
}
