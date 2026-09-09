import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:revoltvpn/logic/connection_settings.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/local_socks_tester.dart';
import 'package:revoltvpn/logic/native_runtime_state.dart';
import 'package:revoltvpn/logic/network_monitor.dart';
import 'package:revoltvpn/logic/secure_socks_session.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

class VpnConnection extends ChangeNotifier {
  static const MethodChannel _nativeControl = MethodChannel('flutter_vless');
  static const _settingsTimeout = Duration(seconds: 5);
  static const _engineInitTimeout = Duration(seconds: 8);
  static const _coreProbeTimeout = Duration(seconds: 4);
  static const _runtimeStateTimeout = Duration(seconds: 4);
  static const _runtimeStopTimeout = Duration(seconds: 8);
  static const _maxRuntimeStartAttempts = 3;

  int _connectEpoch = 0;
  bool _suppressNativeConnect = false;
  bool _disposed = false;

  VpnStatus _status = VpnStatus.disconnected;
  VpnStatus get status => _status;
  String _statusMessage = 'Tap to connect';
  String get statusMessage => _statusMessage;
  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool _adoptedRunningRuntime = false;
  bool get adoptedRunningRuntime => _adoptedRunningRuntime;
  bool _shutdownUnconfirmed = false;
  bool get shutdownUnconfirmed => _shutdownUnconfirmed;
  bool _serverReachable = false;
  bool get serverReachable => _serverReachable;
  ConnectionMode _activeMode = ConnectionMode.tun;
  ConnectionMode get activeMode => _activeMode;
  String _networkTransport = 'unknown';
  String get networkTransport => _networkTransport;

  SecureSocksSession? _lastSecureSocks;
  SecureSocksSession? get activeSocksSession => _lastSecureSocks;
  bool _userDisconnecting = false;

  bool get canTestActiveLocalSocks =>
      !_disposed &&
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

  Future<LocalSocksTestResult> testActiveLocalSocksUdpAssociate() async {
    final active = _lastSecureSocks;
    if (!canTestActiveLocalSocks || active == null) {
      return const LocalSocksTestResult(
        ok: false,
        latencyMs: null,
        message: 'No active authenticated SOCKS5 session.',
      );
    }
    return LocalSocksTester.testUdpAssociate(
      host: '127.0.0.1',
      port: active.port,
      username: active.username,
      password: active.password,
    );
  }

  Timer? _healthTimer;
  StreamSubscription<NetworkSnapshot>? _networkSubscription;
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
    } catch (error, stack) {
      debugPrint('[VPN] Engine init failed: $error');
      debugPrintStack(stackTrace: stack);
    } finally {
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  Future<void> _startEngine() async {
    if (kIsWeb || _disposed) return;
    try {
      await ConnectionSettings.initialize().timeout(_settingsTimeout);
      if (_disposed) return;
      _activeMode = ConnectionSettings.mode;
    } catch (error) {
      debugPrint('[VPN] Connection settings unavailable, using current value: $error');
    }

    _vless = FlutterVless(
      onStatusChanged: (status) {
        if (_disposed) return;
        _mapStatus(status);
      },
    );

    try {
      await _vless
          .initializeVless(
            providerBundleIdentifier: 'com.paladinvpn.app',
            notificationIconResourceType: 'drawable',
            notificationIconResourceName: 'notification_icon',
          )
          .timeout(_engineInitTimeout);
      if (_disposed) return;
      _initialized = true;
    } catch (error) {
      debugPrint('[VPN] VLESS init error: $error');
      return;
    }
    if (_disposed) return;

    try {
      await _adoptNativeRuntimeIfPresent();
    } catch (error) {
      // Initialization remains usable, but connect() will repeat this query and
      // fail closed before creating a server session if state is still unknown.
      debugPrint('[VPN] Initial native runtime adoption query failed: $error');
    }
    if (_disposed) return;

    _networkSubscription = NetworkMonitor.changes.listen(
      (snapshot) {
        if (_disposed) return;
        _networkTransport = snapshot.transport;
        notifyListeners();
      },
      onError: (Object error) => debugPrint('[VPN] Network monitor error: $error'),
    );

    unawaited(_checkHealth());
    _healthTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_checkHealth()),
    );

    try {
      final coreVersion = await _vless.getCoreVersion().timeout(_coreProbeTimeout);
      if (!_disposed) debugPrint('[VPN] Xray core version: $coreVersion');
    } catch (error) {
      debugPrint('[VPN] Bounded Xray version probe failed: $error');
    }
  }

  String get _connectedLabel => switch (_activeMode) {
        ConnectionMode.proxy => 'SOCKS5 gateway active',
        ConnectionMode.tun => 'Secured',
      };

  bool _isCurrentConnect(int epoch) =>
      !_disposed && epoch == _connectEpoch && !_userDisconnecting;

  void _mapStatus(VlessStatus status) {
    if (_disposed) return;
    switch (status.connectionState) {
      case VlessConnectionState.connected:
        if (_suppressNativeConnect || _userDisconnecting) return;
        if (_connectEpoch == 0) _adoptedRunningRuntime = true;
        _shutdownUnconfirmed = false;
        _errorMessage = null;
        _setStatus(VpnStatus.connected, _connectedLabel);
        break;
      case VlessConnectionState.disconnected:
        // Native generation filtering makes this an authoritative release of
        // the runtime latch even if a prior stop call timed out in Dart.
        _shutdownUnconfirmed = false;
        if (_suppressNativeConnect || _userDisconnecting) return;
        _errorMessage = null;
        _clearRuntimeSnapshot();
        _setStatus(VpnStatus.disconnected, 'Tap to connect');
        break;
      case VlessConnectionState.connecting:
        if (_suppressNativeConnect || _userDisconnecting) return;
        _setStatus(VpnStatus.connecting, 'Establishing tunnel…');
        break;
      case VlessConnectionState.disconnecting:
        if (_userDisconnecting) return;
        _setStatus(VpnStatus.disconnecting, 'Tearing down…');
        break;
      case VlessConnectionState.unknown:
        if (_suppressNativeConnect || _userDisconnecting) return;
        if (_status != VpnStatus.connected && _status != VpnStatus.disconnected) {
          _errorMessage = 'The VPN runtime reported an unknown state.';
          _setStatus(VpnStatus.error, 'Connection state unknown');
        }
        break;
    }
  }

  Future<NativeRuntimeState> _queryNativeRuntimeState() async {
    final raw = await _nativeControl
        .invokeMapMethod<Object?, Object?>('queryRuntimeState')
        .timeout(_runtimeStateTimeout);
    if (raw == null) {
      throw const FormatException('Native runtime state response was empty.');
    }
    return NativeRuntimeState.fromMap(raw);
  }

  Future<bool> _adoptNativeRuntimeIfPresent() async {
    if (kIsWeb || !_initialized || _disposed) return false;
    final adoptionEpoch = _connectEpoch;
    final snapshot = await _queryNativeRuntimeState();
    if (!nativeRuntimeAdoptionStillCurrent(
      capturedEpoch: adoptionEpoch,
      currentEpoch: _connectEpoch,
      disposed: _disposed,
      disconnecting: _userDisconnecting,
    )) {
      return false;
    }
    if (!snapshot.ownsGeneration) return false;

    _adoptedRunningRuntime = true;
    _shutdownUnconfirmed = false;
    _activeMode = snapshot.proxyOnly ? ConnectionMode.proxy : ConnectionMode.tun;
    _suppressNativeConnect = false;
    _errorMessage = null;
    if (snapshot.runtimeReady) {
      _setStatus(VpnStatus.connected, _connectedLabel);
    } else {
      _setStatus(VpnStatus.connecting, 'Restoring existing route…');
    }
    return true;
  }

  Future<bool> connect({bool skipAdBypass = false}) async {
    if (_shutdownUnconfirmed) {
      _errorMessage =
          'A previous VPN runtime has not confirmed shutdown. Retry disconnect before starting another session.';
      _setStatus(VpnStatus.error, 'Shutdown must be confirmed');
      return false;
    }
    if (_disposed ||
        _userDisconnecting ||
        _status == VpnStatus.connected ||
        _status == VpnStatus.connecting ||
        _status == VpnStatus.disconnecting) {
      return false;
    }

    final connectEpoch = ++_connectEpoch;
    _suppressNativeConnect = false;
    _userDisconnecting = false;
    _errorMessage = null;
    _setStatus(VpnStatus.connecting, 'Preparing connection…');

    try {
      await ConnectionSettings.initialize().timeout(_settingsTimeout);
    } catch (error) {
      if (!_isCurrentConnect(connectEpoch)) return false;
      debugPrint('[VPN] Connection settings preparation failed: $error');
      _suppressNativeConnect = true;
      _errorMessage = 'Connection settings could not be loaded.';
      _setStatus(VpnStatus.error, 'Preparation failed');
      return false;
    }
    if (!_isCurrentConnect(connectEpoch)) return false;
    _activeMode = ConnectionSettings.mode;

    if (!kIsWeb && !_initialized) {
      _suppressNativeConnect = true;
      _errorMessage = 'VPN service unavailable.';
      _setStatus(VpnStatus.error, 'Service unavailable');
      return false;
    }

    if (!kIsWeb) {
      try {
        if (await _adoptNativeRuntimeIfPresent()) return false;
      } catch (error) {
        if (!_isCurrentConnect(connectEpoch)) return false;
        debugPrint('[VPN] Native runtime preflight failed: $error');
        _suppressNativeConnect = true;
        _errorMessage =
            'Android could not prove that no previous VPN runtime is still active.';
        _setStatus(VpnStatus.error, 'Runtime state unavailable');
        return false;
      }
      if (!_isCurrentConnect(connectEpoch)) return false;
    }

    if (!kIsWeb && _activeMode == ConnectionMode.tun) {
      try {
        final ok = await _vless.requestPermission();
        if (!_isCurrentConnect(connectEpoch)) return false;
        if (!ok) {
          _suppressNativeConnect = true;
          _errorMessage = 'VPN permission denied.';
          _setStatus(VpnStatus.error, 'Permission required');
          return false;
        }
      } catch (error) {
        if (!_isCurrentConnect(connectEpoch)) return false;
        debugPrint('[VPN] Permission request failed: $error');
        _suppressNativeConnect = true;
        _errorMessage = 'Android could not complete the VPN permission request.';
        _setStatus(VpnStatus.error, 'Permission failed');
        return false;
      }
    }

    if (kIsWeb) {
      await Future.delayed(const Duration(seconds: 1));
      if (!_isCurrentConnect(connectEpoch)) return false;
      _setStatus(VpnStatus.connected, 'Secured (dev mode)');
      return true;
    }

    _setStatus(VpnStatus.connecting, 'Fetching config…');
    late final HivemindConfigLease configLease;
    try {
      configLease = await HivemindService.fetchConfigLeaseDirectly(
        skipAdBypass: skipAdBypass,
        onAttempt: (attempt, total) {
          if (_isCurrentConnect(connectEpoch)) {
            _setStatus(VpnStatus.connecting, 'Contacting server ($attempt/$total)…');
          }
        },
      );
    } catch (error) {
      if (!_isCurrentConnect(connectEpoch)) return false;
      debugPrint('[VPN] Config fetch error: $error');
      final text = error.toString();
      if (text.contains('Cancelled')) return false;
      _suppressNativeConnect = true;
      _errorMessage = text.contains('timed out') || text.contains('Session not activated')
          ? 'The server did not respond in time. Check your connection and try again.'
          : 'The VPN configuration could not be obtained safely.';
      _setStatus(VpnStatus.error, 'Config unavailable');
      return false;
    }

    if (!_isCurrentConnect(connectEpoch)) return false;
    final leaseClock = Stopwatch()..start();
    try {
      final parsed = FlutterVless.parse(configLease.vlessUrl);
      final baseConfig = parsed.getFullConfiguration();
      final remark = parsed.remark.isNotEmpty ? parsed.remark : 'Revolt VPN';
      final verifyLocalSocks = _activeMode == ConnectionMode.proxy;
      Object? lastStartError;

      for (var attempt = 1; attempt <= _maxRuntimeStartAttempts; attempt++) {
        if (!_isCurrentConnect(connectEpoch)) return false;
        final secureSocks = await SecureSocksSession.create(baseConfig);
        _suppressNativeConnect = false;
        _setStatus(
          VpnStatus.connecting,
          attempt == 1 ? 'Starting secure route…' : 'Retrying secure route ($attempt/$_maxRuntimeStartAttempts)…',
        );

        try {
          await _startRuntime(
            config: secureSocks.configJson,
            remark: remark,
            proxyOnly: verifyLocalSocks,
          );
          if (!_isCurrentConnect(connectEpoch)) return false;
          _setStatus(
            VpnStatus.connecting,
            verifyLocalSocks ? 'Waiting for local SOCKS5…' : 'Waiting for VPN interface…',
          );
          if (!await _waitForNativeConnected(connectEpoch)) {
            throw StateError('VPN runtime did not report CONNECTED');
          }
          if (verifyLocalSocks) {
            _setStatus(VpnStatus.connecting, 'Checking Local SOCKS5…');
            if (!await _waitForLocalSocksListener(secureSocks, connectEpoch)) {
              throw StateError('Local SOCKS5 listener did not become ready');
            }
          }
          if (!_isCurrentConnect(connectEpoch)) return false;

          final initialRemaining = configLease.remainingAfter(leaseClock.elapsed);
          if (initialRemaining <= 0) {
            throw StateError('Server session expired during runtime startup');
          }
          _setStatus(VpnStatus.connecting, 'Arming session deadline…');
          await setNativeSessionDeadline(initialRemaining);
          if (!_isCurrentConnect(connectEpoch)) return false;

          _lastSecureSocks = secureSocks;
          _shutdownUnconfirmed = false;
          _errorMessage = null;
          _setStatus(VpnStatus.connected, _connectedLabel);
          return true;
        } catch (error) {
          lastStartError = error;
          if (!_isCurrentConnect(connectEpoch)) return false;
          debugPrint('[VPN] Runtime start attempt $attempt failed: $error');
          _suppressNativeConnect = true;
          try {
            await _stopRuntime();
            _shutdownUnconfirmed = false;
          } catch (stopError) {
            debugPrint('[VPN] Runtime cleanup failed after start error: $stopError');
            if (!_isCurrentConnect(connectEpoch)) return false;
            _shutdownUnconfirmed = true;
            _suppressNativeConnect = false;
            _errorMessage = 'The VPN runtime could not be stopped safely.';
            _setStatus(VpnStatus.error, 'Shutdown failed');
            return false;
          }
          _clearRuntimeSnapshot();
          if (attempt < _maxRuntimeStartAttempts) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        }
      }

      debugPrint('[VPN] Exhausted runtime start attempts: $lastStartError');
      await _cleanupServerCredentialAfterFailedStart();
      if (!_isCurrentConnect(connectEpoch)) return false;
      _suppressNativeConnect = true;
      _errorMessage = _activeMode == ConnectionMode.proxy
          ? 'SOCKS5 gateway failed to start after safe retries.'
          : 'Connection failed to start after safe retries.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    } catch (error) {
      if (!_isCurrentConnect(connectEpoch)) return false;
      debugPrint('[VPN] Configuration/runtime preparation failed: $error');
      await _cleanupServerCredentialAfterFailedStart();
      if (!_isCurrentConnect(connectEpoch)) return false;
      _suppressNativeConnect = true;
      _errorMessage = 'The VPN route could not be prepared safely.';
      _setStatus(VpnStatus.error, 'Connection failed');
      return false;
    } finally {
      leaseClock.stop();
    }
  }

  Future<void> _cleanupServerCredentialAfterFailedStart() async {
    if (_shutdownUnconfirmed) return;
    try {
      final deviceId = await CryptoService.getDeviceId();
      final cleaned = await HivemindService.revokeActiveSession(
        deviceId,
        drainPendingActivation: true,
      );
      if (!cleaned) {
        debugPrint('[VPN] Server credential cleanup was not confirmed.');
      }
    } catch (error) {
      // Every runtime-start failure reaches this helper only after native/local
      // cleanup was proven. Remote failure therefore keeps the local client
      // stopped while retaining authorization for a later cleanup attempt.
      debugPrint('[VPN] Server credential cleanup failed: $error');
    }
  }

  Future<void> _startRuntime({
    required String config,
    required String remark,
    required bool proxyOnly,
  }) async {
    await _vless.startVless(remark: remark, config: config, proxyOnly: proxyOnly);
  }

  Future<bool> _waitForLocalSocksListener(
    SecureSocksSession session,
    int connectEpoch,
  ) async {
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!_isCurrentConnect(connectEpoch)) return false;
      final result = await LocalSocksTester.testListener(
        host: '127.0.0.1',
        port: session.port,
        username: session.username,
        password: session.password,
      );
      if (!_isCurrentConnect(connectEpoch)) return false;
      if (result.ok) return true;
      if (attempt < 11) await Future.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<bool> _waitForNativeConnected(int connectEpoch) async {
    for (var attempt = 0; attempt < 32; attempt++) {
      if (!_isCurrentConnect(connectEpoch)) return false;
      if (_status == VpnStatus.connected) return true;
      if (_status == VpnStatus.error || _status == VpnStatus.disconnected) return false;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return _isCurrentConnect(connectEpoch) && _status == VpnStatus.connected;
  }

  Future<void> _stopRuntime() async {
    await _vless.stopVless().timeout(_runtimeStopTimeout);
  }

  Future<void> setNativeSessionDeadline(int remainingSeconds) async {
    if (kIsWeb) return;
    if (_disposed) throw StateError('VPN connection has been disposed');
    if (!_initialized) throw StateError('VPN native service is not initialized');
    if (remainingSeconds < 0) {
      throw ArgumentError.value(remainingSeconds, 'remainingSeconds');
    }
    await _nativeControl.invokeMethod<void>(
      'setSessionDeadline',
      <String, Object>{'remainingSeconds': remainingSeconds},
    );
  }

  Future<bool> disconnect() async {
    if (_disposed || _status == VpnStatus.disconnecting) return false;
    _connectEpoch++;
    _suppressNativeConnect = true;
    _userDisconnecting = true;
    HivemindService.cancel();
    _setStatus(VpnStatus.disconnecting, 'Tearing down…');

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (_disposed) return false;
      _shutdownUnconfirmed = false;
      _clearRuntimeSnapshot();
      _setStatus(VpnStatus.disconnected, 'Tap to connect');
      _userDisconnecting = false;
      return true;
    }

    try {
      await _stopRuntime();
    } catch (error) {
      if (_disposed) return false;
      debugPrint('[VPN] VLESS stop error: $error');
      _shutdownUnconfirmed = true;
      // Do not erase the runtime snapshot. The native bridge failed to prove
      // shutdown, so the safest client state is "uncertain" with credentials
      // and session deadline still available for recovery/retry.
      _errorMessage = 'Android did not confirm VPN shutdown.';
      _setStatus(VpnStatus.error, 'Shutdown unconfirmed');
      _userDisconnecting = false;
      _suppressNativeConnect = false;
      return false;
    }

    if (_disposed) return false;
    _shutdownUnconfirmed = false;
    _errorMessage = null;
    _clearRuntimeSnapshot();
    _setStatus(VpnStatus.disconnected, 'Tap to connect');
    _userDisconnecting = false;
    _suppressNativeConnect = false;
    return true;
  }

  void _clearRuntimeSnapshot() {
    _lastSecureSocks = null;
    _adoptedRunningRuntime = false;
  }

  void _setStatus(VpnStatus status, String message) {
    if (_disposed) return;
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  Future<void> _checkHealth() async {
    if (_disposed || !_initialized || _status == VpnStatus.connected) return;
    final reachable = await HivemindService.checkHealth();
    if (_disposed || _status == VpnStatus.connected) return;
    _serverReachable = reachable;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectEpoch++;
    _suppressNativeConnect = true;
    _userDisconnecting = true;
    HivemindService.cancel();
    _healthTimer?.cancel();
    _networkSubscription?.cancel();
    super.dispose();
  }
}
