import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/notification_service.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';

class SessionTimer extends ChangeNotifier with WidgetsBindingObserver {
  Timer? _timer;
  int _tickCount = 0;
  bool _appBackgrounded = false;

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

  static const String _supportRewardClaimKey =
      'support_reward_claimed_active_session';
  static const FlutterSecureStorage _supportStorage = FlutterSecureStorage();

  static const int _maxConsecutiveFailures = 3;
  static const int _maxOfflineSeconds = 120;
  int _offlineSeconds = 0;

  static const int _pollIntervalSeconds = 5;
  static const int _backgroundPollIntervalSeconds = 30;

  int _lastUsedBytes = 0;
  Stopwatch? _sinceLastSuccessfulSync;
  double _currentSpeedKBps = 0.0;

  SessionTimer({required this.vpnConnection}) {
    WidgetsBinding.instance.addObserver(this);
    vpnConnection.addListener(_onVpnConnectionChanged);
    unawaited(_loadSupportRewardState());

    // VpnConnection is eager and can report an already-running native tunnel
    // before this provider is created. ChangeNotifier listeners do not replay
    // old events, so always evaluate the current state once after construction.
    unawaited(Future.microtask(_onVpnConnectionChanged));
  }

  int get remaining => _remainingSeconds;
  bool get isRunning => _timer != null && _timer!.isActive;
  bool get isExpired => _remainingSeconds <= 0 && !isRunning;
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
      claimed =
          (await _supportStorage.read(key: _supportRewardClaimKey)) == '1';
    } catch (e) {
      debugPrint('[Timer] Failed to load support reward state: $e');
    }

    if (epoch != _supportStateEpoch) return;
    _supportRewardClaimed = claimed;
    _supportRewardStateLoaded = true;
    notifyListeners();
  }

  Future<void> _persistSupportRewardState(bool value) async {
    try {
      await _supportStorage.write(
        key: _supportRewardClaimKey,
        value: value ? '1' : '0',
      );
    } catch (e) {
      debugPrint('[Timer] Failed to persist support reward state: $e');
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
    // A live tunnel with a stopped clock is always wrong, whether this process
    // adopted an existing runtime, attached late, or recovered from a blip.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_isDisconnecting) {
      debugPrint('[Timer] Connected with a stopped clock - resuming.');
      _resumeTicking();
      return;
    }

    final hadActiveSession = isRunning || _hasSyncedOnce;
    if (!hadActiveSession || _isDisconnecting) return;

    if (vpnConnection.status == VpnStatus.error) {
      unawaited(_doDisconnect('VPN entered error state'));
      return;
    }

    if (vpnConnection.status == VpnStatus.disconnected) {
      unawaited(_doDisconnect('VPN tunnel dropped'));
    }
  }

  Future<void> start() async {
    _sessionEpoch++;
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
    _isDisconnecting = false;
    _appBackgrounded = false;
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

  void _tick(Timer t) {
    if (_isDisconnecting) return;

    if (_hasSyncedOnce) {
      _reconcileElapsedTime();
    }

    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _offlineSeconds++;
      if (_offlineSeconds >= _maxOfflineSeconds) {
        unawaited(_doDisconnect('Server unreachable'));
        return;
      }
    }

    if (_hasSyncedOnce && _remainingSeconds <= 0) {
      unawaited(_doDisconnect('Session expired'));
      return;
    }

    _tickCount++;
    final pollInterval = _appBackgrounded
        ? _backgroundPollIntervalSeconds
        : _pollIntervalSeconds;
    if (_tickCount % pollInterval == 0) {
      unawaited(_syncWithHivemind());
    }

    notifyListeners();

    if (_hasSyncedOnce && vpnConnection.status == VpnStatus.connected) {
      NotificationService.updateTimer(formatted);
    }
  }

  /// Force a control-plane refresh after an event that changes the session
  /// server-side. If a periodic sync is already in flight, wait for it and
  /// issue a fresh request so the event cannot be hidden behind the busy guard.
  Future<void> syncNow() async {
    final requestedEpoch = _sessionEpoch;
    while (requestedEpoch == _sessionEpoch && !_isDisconnecting) {
      final active = _syncEpochInProgress == requestedEpoch
          ? _syncCompletion
          : null;
      if (active != null) {
        await active.future;
        continue;
      }
      await _syncWithHivemind();
      return;
    }
  }

  Future<void> disconnect({String reason = 'User requested'}) async {
    await _doDisconnect(reason);
  }

  Future<void> _doDisconnect(String reason) async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    _sessionEpoch++;
    debugPrint('[Timer] Disconnecting: $reason');

    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _remainingSeconds = 0;
    _remainingAtLastSync = 0;
    _hasSyncedOnce = false;
    _sinceLastSuccessfulSync?.stop();
    _sinceLastSuccessfulSync = null;
    NotificationService.reset();
    notifyListeners();

    await vpnConnection.disconnect();

    _isDisconnecting = false;
    notifyListeners();
  }

  int _readNonNegativeInt(dynamic value, int fallback) {
    if (value is int) return value >= 0 ? value : fallback;
    if (value is num && value >= 0) return value.toInt();
    return fallback;
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

      final base = Uri.parse('${AppConfig.hivemindApiPublic}/session/status');
      final url = base.replace(queryParameters: {'device_id': deviceId});
      final response = await HivemindService.controlGet(url);
      if (epoch != _sessionEpoch || _isDisconnecting) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          debugPrint('[Timer] Invalid session payload type.');
          _markSyncFailure(epoch);
          return;
        }
        final data = decoded;

        final activeValue = data['active'];
        if (activeValue is! bool) {
          debugPrint('[Timer] Session payload missing boolean active state.');
          _markSyncFailure(epoch);
          return;
        }
        if (!activeValue) {
          await _doDisconnect('Server ended session');
          return;
        }

        final expiresValue = data['expires_in_seconds'];
        if (expiresValue is! num ||
            !expiresValue.isFinite ||
            expiresValue < 0) {
          debugPrint('[Timer] Session payload has invalid expiry.');
          _markSyncFailure(epoch);
          return;
        }

        final elapsedMs = _sinceLastSuccessfulSync?.elapsedMilliseconds;
        _remainingAtLastSync = expiresValue.toInt();
        _remainingSeconds = _remainingAtLastSync;
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);

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

        if (data['cap_exhausted'] == true) {
          await _doDisconnect('Data cap reached');
          return;
        }

        if (epoch != _sessionEpoch || _isDisconnecting) return;
        try {
          await vpnConnection.setNativeSessionDeadline(_remainingAtLastSync);
        } catch (e) {
          debugPrint('[Timer] Failed to arm native session deadline: $e');
          await _doDisconnect('Native session deadline unavailable');
          return;
        }
        if (epoch != _sessionEpoch || _isDisconnecting) return;
        _consecutiveFailures = 0;
        _offlineSeconds = 0;
        _hasSyncedOnce = true;
        notifyListeners();
      } else {
        _markSyncFailure(epoch);
      }
    } catch (e) {
      if (epoch == _sessionEpoch && !_isDisconnecting) {
        debugPrint('Hivemind sync error: $e');
        _markSyncFailure(epoch);
      }
    } finally {
      if (_syncEpochInProgress == epoch) {
        _syncEpochInProgress = null;
      }
      if (identical(_syncCompletion, completion)) {
        _syncCompletion = null;
      }
      if (!completion.isCompleted) completion.complete();
    }
  }

  void _markSyncFailure(int epoch) {
    if (epoch != _sessionEpoch || _isDisconnecting) return;
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners();
    }
  }

  void _reconcileElapsedTime() {
    final clock = _sinceLastSuccessfulSync;
    if (!_hasSyncedOnce || clock == null) return;

    final elapsed = clock.elapsed.inSeconds;
    _remainingSeconds =
        (_remainingAtLastSync - elapsed).clamp(0, 1 << 31).toInt();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _appBackgrounded = true;
      return;
    }

    if (state != AppLifecycleState.resumed || _isDisconnecting) return;
    _appBackgrounded = false;
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    _sinceLastSuccessfulSync?.stop();
    super.dispose();
  }
}
