import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/notification_service.dart';
import 'package:revoltvpn/logic/session_accounting.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class SessionTimer extends ChangeNotifier with WidgetsBindingObserver {
  Timer? _timer;
  int _tickCount = 0;
  final VpnConnection vpnConnection;

  int _remainingSeconds = 0;
  int _remainingAtLastSync = 0;
  int _usedBytes = 0;
  bool _hasSyncedOnce = false;
  int _consecutiveFailures = 0;
  bool _isDisconnecting = false;
  int? _syncEpochInProgress;
  Completer<void>? _syncCompletion;
  int _sessionEpoch = 0;

  bool _supportRewardClaimed = false;
  bool _supportRewardStateLoaded = false;
  int _supportStateEpoch = 0;
  static const String _supportRewardClaimKey = 'support_reward_claimed_active_session';
  static const FlutterSecureStorage _supportStorage = FlutterSecureStorage();

  static const int _maxConsecutiveFailures = 3;
  static const int _maxOfflineSeconds = 120;
  static const int _pollIntervalSeconds = 60;
  int _offlineSeconds = 0;

  int _lastUsedBytes = 0;
  Stopwatch? _sinceLastSuccessfulSync;
  double _currentSpeedKBps = 0.0;

  SessionTimer({required this.vpnConnection}) {
    WidgetsBinding.instance.addObserver(this);
    vpnConnection.addListener(_onVpnConnectionChanged);
    unawaited(_loadSupportRewardState());
    unawaited(Future.microtask(_onVpnConnectionChanged));
  }

  int get remaining => _remainingSeconds;
  bool get isRunning => _timer?.isActive == true;
  bool get isExpired => _hasSyncedOnce && _remainingSeconds <= 0 && !isRunning;
  bool get hasSyncedOnce => _hasSyncedOnce;
  bool get supportRewardClaimed => _supportRewardClaimed;
  bool get supportRewardStateLoaded => _supportRewardStateLoaded;
  int get usedBytes => _usedBytes;
  double get currentSpeedKBps => _currentSpeedKBps;

  String get formatted {
    final h = (_remainingSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((_remainingSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _loadSupportRewardState() async {
    final epoch = _supportStateEpoch;
    var claimed = false;
    try {
      claimed = (await _supportStorage.read(key: _supportRewardClaimKey)) == '1';
    } catch (error) {
      debugPrint('[Timer] Failed to load support reward state: $error');
    }
    if (epoch != _supportStateEpoch) return;
    _supportRewardClaimed = claimed;
    _supportRewardStateLoaded = true;
    notifyListeners();
  }

  Future<void> _persistSupportRewardState(bool value) async {
    try {
      await _supportStorage.write(key: _supportRewardClaimKey, value: value ? '1' : '0');
    } catch (error) {
      debugPrint('[Timer] Failed to persist support reward state: $error');
    }
  }

  Future<void> markSupportRewardClaimed() async {
    if (_supportRewardClaimed) return;
    _supportRewardClaimed = true;
    _supportRewardStateLoaded = true;
    notifyListeners();
    await _persistSupportRewardState(true);
  }

  void _onVpnConnectionChanged() {
    final canResumeExistingSession =
        vpnConnection.adoptedRunningRuntime || _hasSyncedOnce;
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_isDisconnecting &&
        canResumeExistingSession) {
      debugPrint('[Timer] Resuming clock for an adopted/synced runtime.');
      _resumeTicking();
      return;
    }

    final hadActiveSession = isRunning || _hasSyncedOnce;
    if (!hadActiveSession || _isDisconnecting) return;
    if (vpnConnection.status == VpnStatus.error) {
      unawaited(_doDisconnect('VPN entered error state'));
    } else if (vpnConnection.status == VpnStatus.disconnected) {
      unawaited(_doDisconnect('VPN tunnel dropped'));
    }
  }

  Future<void> start() async {
    _sessionEpoch++;
    _resetSessionMetrics();
    _isDisconnecting = false;
    NotificationService.reset();
    _supportStateEpoch++;
    _supportRewardClaimed = false;
    _supportRewardStateLoaded = true;
    unawaited(_persistSupportRewardState(false));
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    notifyListeners();
    unawaited(_syncWithHivemind());
  }

  void _resetSessionMetrics() {
    _remainingSeconds = 0;
    _remainingAtLastSync = 0;
    _usedBytes = 0;
    _lastUsedBytes = 0;
    _sinceLastSuccessfulSync?.stop();
    _sinceLastSuccessfulSync = null;
    _currentSpeedKBps = 0.0;
    _tickCount = 0;
    _hasSyncedOnce = false;
    _consecutiveFailures = 0;
    _offlineSeconds = 0;
  }

  void _tick(Timer timer) {
    if (_isDisconnecting) return;
    if (_hasSyncedOnce) _reconcileElapsedTime();
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _offlineSeconds++;
      if (_offlineSeconds >= _maxOfflineSeconds) {
        unawaited(_doDisconnect('Server unreachable'));
        return;
      }
    }
    if (_hasSyncedOnce && _remainingSeconds <= 0) {
      unawaited(_doDisconnect('Session expired', revokeServer: false));
      return;
    }
    _tickCount++;
    if (_tickCount % _pollIntervalSeconds == 0) unawaited(_syncWithHivemind());
    notifyListeners();
    if (_hasSyncedOnce && vpnConnection.status == VpnStatus.connected) {
      NotificationService.updateTimer(formatted);
    }
  }

  Future<void> syncNow() async {
    final requestedEpoch = _sessionEpoch;
    while (requestedEpoch == _sessionEpoch && !_isDisconnecting) {
      final active = _syncEpochInProgress == requestedEpoch ? _syncCompletion : null;
      if (active != null) {
        await active.future;
        continue;
      }
      await _syncWithHivemind();
      return;
    }
  }

  Future<void> disconnect({String reason = 'User requested'}) => _doDisconnect(reason);

  Future<void> _doDisconnect(
    String reason, {
    bool revokeServer = true,
  }) async {
    if (_isDisconnecting) return;
    final hadActiveSession = isRunning || _hasSyncedOnce;
    _isDisconnecting = true;
    _sessionEpoch++;
    debugPrint('[Timer] Disconnecting: $reason');
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    NotificationService.reset();
    notifyListeners();

    final stopped = await vpnConnection.disconnect();
    if (stopped) {
      try {
        if (revokeServer) {
          // Also run for a cancelled CONNECTING state. The server may already
          // have minted a credential even though the session timer never began.
          final deviceId = await CryptoService.getDeviceId();
          final revoked = await HivemindService.revokeActiveSession(
            deviceId,
            drainPendingActivation: true,
          );
          if (!revoked) {
            debugPrint('[Timer] Server session revoke was not confirmed.');
          }
        } else if (hadActiveSession) {
          await HivemindService.clearActiveSessionAuthorization();
        }
      } catch (error) {
        // Local/native shutdown is authoritative for device traffic. A remote
        // control-plane failure must not resurrect the local VPN state.
        debugPrint('[Timer] Server session cleanup failed: $error');
      }
      _resetSessionMetrics();
      _isDisconnecting = false;
      notifyListeners();
      return;
    }

    // Native shutdown was not proven. Preserve both the last server-derived
    // session state and its authorization nonce: the tunnel may still be alive,
    // so quota/deadline synchronization must continue fail-closed.
    _isDisconnecting = false;
    if (hadActiveSession && !isRunning) {
      _timer = Timer.periodic(const Duration(seconds: 1), _tick);
      unawaited(_syncWithHivemind());
    }
    notifyListeners();
  }

  Future<void> _syncWithHivemind() async {
    if (_isDisconnecting) return;
    final epoch = _sessionEpoch;
    if (_syncEpochInProgress == epoch) return;
    final completion = Completer<void>();
    _syncCompletion = completion;
    _syncEpochInProgress = epoch;

    try {
      final deviceId = await CryptoService.getDeviceId();
      if (epoch != _sessionEpoch || _isDisconnecting) return;
      final response = await HivemindService.sessionStatus(deviceId);
      if (epoch != _sessionEpoch || _isDisconnecting) return;

      if (response.statusCode != 200) {
        _markSyncFailure(epoch);
        return;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _markSyncFailure(epoch);
        return;
      }
      final activeValue = decoded['active'];
      if (activeValue is! bool) {
        _markSyncFailure(epoch);
        return;
      }
      if (!activeValue) {
        await _doDisconnect('Server ended session', revokeServer: false);
        return;
      }

      final accounting = SessionAccounting.fromActiveStatus(decoded);
      if (accounting.expired) {
        await _doDisconnect('Session expired', revokeServer: false);
        return;
      }
      if (accounting.dataCapReached) {
        await _doDisconnect('Data cap reached', revokeServer: false);
        return;
      }

      final elapsedMs = _sinceLastSuccessfulSync?.elapsedMilliseconds;
      _remainingAtLastSync = accounting.expiresInSeconds;
      _remainingSeconds = _remainingAtLastSync;
      _usedBytes = accounting.usedBytes;
      final deltaBytes = _usedBytes - _lastUsedBytes;
      if (_hasSyncedOnce && elapsedMs != null && elapsedMs > 0) {
        _currentSpeedKBps = deltaBytes > 0
            ? (deltaBytes / (elapsedMs / 1000.0)) / 1000.0
            : 0.0;
      } else {
        _currentSpeedKBps = 0.0;
      }
      _lastUsedBytes = _usedBytes;
      _sinceLastSuccessfulSync?.stop();
      _sinceLastSuccessfulSync = Stopwatch()..start();

      if (epoch != _sessionEpoch || _isDisconnecting) return;
      try {
        await vpnConnection.setNativeSessionDeadline(_remainingAtLastSync);
      } catch (error) {
        debugPrint('[Timer] Failed to arm native session deadline: $error');
        await _doDisconnect('Native session deadline unavailable');
        return;
      }
      if (epoch != _sessionEpoch || _isDisconnecting) return;
      _consecutiveFailures = 0;
      _offlineSeconds = 0;
      _hasSyncedOnce = true;
      notifyListeners();
    } catch (error) {
      if (epoch == _sessionEpoch && !_isDisconnecting) {
        debugPrint('[Timer] Hivemind sync error: $error');
        _markSyncFailure(epoch);
      }
    } finally {
      if (_syncEpochInProgress == epoch) _syncEpochInProgress = null;
      if (identical(_syncCompletion, completion)) _syncCompletion = null;
      if (!completion.isCompleted) completion.complete();
    }
  }

  void _markSyncFailure(int epoch) {
    if (epoch != _sessionEpoch || _isDisconnecting) return;
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) notifyListeners();
  }

  void _reconcileElapsedTime() {
    final clock = _sinceLastSuccessfulSync;
    if (!_hasSyncedOnce || clock == null) return;
    final elapsed = clock.elapsed.inSeconds;
    _remainingSeconds = (_remainingAtLastSync - elapsed).clamp(0, _remainingAtLastSync).toInt();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _isDisconnecting) return;
    if (vpnConnection.status != VpnStatus.connected) return;
    _reconcileElapsedTime();
    if (!isRunning && (vpnConnection.adoptedRunningRuntime || _hasSyncedOnce)) {
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
    unawaited(_syncWithHivemind());
    notifyListeners();
  }

  @override
  void dispose() {
    _sessionEpoch++;
    _supportStateEpoch++;
    _isDisconnecting = true;
    WidgetsBinding.instance.removeObserver(this);
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    _sinceLastSuccessfulSync?.stop();
    super.dispose();
  }
}
