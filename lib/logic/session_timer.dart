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
  bool _syncInProgress = false;
  bool _supportRewardClaimed = false;
  bool _supportRewardStateLoaded = false;
  int _supportStateEpoch = 0;

  static const String _supportRewardClaimKey =
      'support_reward_claimed_active_session';
  static const FlutterSecureStorage _supportStorage = FlutterSecureStorage();

  static const int _maxConsecutiveFailures = 3;
  static const int _pollIntervalSeconds = 5;
  static const int _backgroundPollIntervalSeconds = 30;

  final Stopwatch _monotonicClock = Stopwatch()..start();
  Duration? _lastSuccessfulSyncElapsed;
  int _lastUsedBytes = 0;
  double _currentSpeedKBps = 0.0;

  SessionTimer({required this.vpnConnection}) {
    WidgetsBinding.instance.addObserver(this);
    vpnConnection.addListener(_onVpnConnectionChanged);
    unawaited(_loadSupportRewardState());
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
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        vpnConnection.adoptedRunningRuntime) {
      _resumeTicking();
      return;
    }

    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_isDisconnecting &&
        _hasSyncedOnce) {
      debugPrint('[Timer] VPN reconnected after blip - resuming.');
      _resumeTicking();
      return;
    }

    final hadActiveSession = isRunning || _hasSyncedOnce;
    if (!hadActiveSession || _isDisconnecting) return;

    if (vpnConnection.status == VpnStatus.connecting) {
      // Do not leave the previous countdown frozen in the foreground
      // notification while the native TUN/Xray path is recovering.
      unawaited(NotificationService.updateTimer('Reconnecting…'));
      return;
    }

    if (vpnConnection.status == VpnStatus.error) {
      _stopForVpnFailure('VPN entered error state');
      return;
    }

    if (vpnConnection.status == VpnStatus.disconnected) {
      unawaited(_doDisconnect('VPN tunnel dropped'));
    }
  }

  void _stopForVpnFailure(String reason) {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    debugPrint('[Timer] Stopping after VPN failure: $reason');

    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _remainingSeconds = 0;
    _remainingAtLastSync = 0;
    _hasSyncedOnce = false;
    _lastSuccessfulSyncElapsed = null;
    _consecutiveFailures = 0;
    NotificationService.reset();
    notifyListeners();
  }

  Future<void> start() async {
    _remainingSeconds = 0;
    _remainingAtLastSync = 0;
    _usedBytes = 0;
    _lastUsedBytes = 0;
    _lastSuccessfulSyncElapsed = null;
    _currentSpeedKBps = 0.0;
    _tickCount = 0;
    _hasSyncedOnce = false;
    _consecutiveFailures = 0;
    _isDisconnecting = false;
    _appBackgrounded = false;
    _monotonicClock
      ..reset()
      ..start();
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

    // Local countdown uses a monotonic clock. Wall-clock changes, timezone
    // changes and automatic time correction cannot extend or shorten a session.
    if (_hasSyncedOnce) {
      _reconcileElapsedTime();
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

  Future<void> disconnect({String reason = 'User requested'}) async {
    await _doDisconnect(reason);
  }

  Future<void> _doDisconnect(String reason) async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    debugPrint('[Timer] Disconnecting: $reason');

    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _remainingSeconds = 0;
    _remainingAtLastSync = 0;
    _hasSyncedOnce = false;
    _lastSuccessfulSyncElapsed = null;
    NotificationService.reset();
    notifyListeners();

    await vpnConnection.disconnect();

    if (!_isDisconnecting) return;
    _isDisconnecting = false;
    notifyListeners();
  }

  int _readNonNegativeInt(dynamic value, int fallback) {
    if (value is int) return value >= 0 ? value : fallback;
    if (value is num && value >= 0) return value.toInt();
    return fallback;
  }

  Future<void> _syncWithHivemind() async {
    if (_isDisconnecting || _syncInProgress) return;
    _syncInProgress = true;
    try {
      final deviceId = await CryptoService.getDeviceId();
      final base = Uri.parse('${AppConfig.hivemindApiPublic}/session/status');
      final url = base.replace(queryParameters: {'device_id': deviceId});
      final response = await HivemindService.directGet(url);
      if (_isDisconnecting) return;

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          debugPrint('[Timer] Invalid session payload type.');
          _markSyncFailure();
          return;
        }
        final data = decoded;

        final activeValue = data['active'];
        if (activeValue is! bool) {
          debugPrint('[Timer] Session payload missing boolean active state.');
          _markSyncFailure();
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
          _markSyncFailure();
          return;
        }

        _remainingAtLastSync = expiresValue.toInt();
        _remainingSeconds = _remainingAtLastSync;
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);

        final nowElapsed = _monotonicClock.elapsed;
        final previousSyncElapsed = _lastSuccessfulSyncElapsed;
        final deltaBytes = _usedBytes - _lastUsedBytes;
        if (_hasSyncedOnce && previousSyncElapsed != null) {
          final elapsedMs =
              (nowElapsed - previousSyncElapsed).inMilliseconds;
          if (deltaBytes > 0 && elapsedMs > 0) {
            _currentSpeedKBps =
                (deltaBytes / (elapsedMs / 1000.0)) / 1000.0;
          } else {
            _currentSpeedKBps = 0.0;
          }
        } else {
          _currentSpeedKBps = 0.0;
        }
        _lastUsedBytes = _usedBytes;
        _lastSuccessfulSyncElapsed = nowElapsed;

        if (data['cap_exhausted'] == true) {
          await _doDisconnect('Data cap reached');
          return;
        }

        _consecutiveFailures = 0;
        _hasSyncedOnce = true;
        notifyListeners();
      } else {
        _markSyncFailure();
      }
    } catch (e) {
      if (!_isDisconnecting) {
        debugPrint('Hivemind sync error: $e');
        _markSyncFailure();
      }
    } finally {
      _syncInProgress = false;
    }
  }

  void _markSyncFailure() {
    _consecutiveFailures++;
    // A control-plane timeout is not tunnel death. Keep counting down from the
    // last authenticated server response and retry; only an explicit inactive
    // response, data-cap response, local expiry, or VPN failure tears down.
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners();
    }
  }

  void _reconcileElapsedTime() {
    final syncedAt = _lastSuccessfulSyncElapsed;
    if (!_hasSyncedOnce || syncedAt == null) return;

    final elapsed = (_monotonicClock.elapsed - syncedAt).inSeconds;
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
    if (vpnConnection.status != VpnStatus.connected &&
        vpnConnection.status != VpnStatus.connecting) {
      return;
    }

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
    super.dispose();
  }
}
