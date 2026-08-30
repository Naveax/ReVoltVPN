import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/notification_service.dart';

class SessionTimer extends ChangeNotifier with WidgetsBindingObserver {
  Timer? _timer;
  int _tickCount = 0;
  bool _appBackgrounded = false;

  final VpnConnection vpnConnection;

  int _remainingSeconds = 0;
  int _usedBytes       = 0;

  bool _hasSyncedOnce       = false;
  int  _consecutiveFailures = 0;
  bool _isDisconnecting     = false;
  bool _syncInProgress      = false;

  static const int _maxConsecutiveFailures = 3;
  static const int _maxOfflineSeconds = 120;
  int _offlineSeconds = 0;

  static const int _pollIntervalSeconds = 5;
  static const int _backgroundPollIntervalSeconds = 30;

  int      _lastUsedBytes    = 0;
  double   _currentSpeedKBps = 0.0;
  DateTime? _lastSyncAt;

  SessionTimer({required this.vpnConnection}) {
    WidgetsBinding.instance.addObserver(this);
    vpnConnection.addListener(_onVpnConnectionChanged);
  }

  int  get remaining        => _remainingSeconds;
  bool get isRunning        => _timer != null && _timer!.isActive;
  bool get isExpired        => _remainingSeconds <= 0 && !isRunning;
  bool get hasSyncedOnce    => _hasSyncedOnce;

  int    get usedBytes      => _usedBytes;
  double get currentSpeedKBps => _currentSpeedKBps;

  String get formatted {
    final h = (_remainingSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((_remainingSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _onVpnConnectionChanged() {
    // Restore timer if VPN was already running at app launch.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        vpnConnection.isStartupRestoration) {
      _resumeTicking();
      return;
    }

    // Resume after brief tunnel disconnection.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_isDisconnecting &&
        _hasSyncedOnce) {
      debugPrint('[Timer] VPN reconnected after blip — resuming.');
      _resumeTicking();
      return;
    }

    if (vpnConnection.status == VpnStatus.disconnected && !_isDisconnecting) {
      _doDisconnect('VPN tunnel dropped');
    }
  }

  Future<void> start() async {
    _remainingSeconds    = 0;
    _usedBytes           = 0;
    _lastUsedBytes       = 0;
    _currentSpeedKBps    = 0.0;
    _lastSyncAt          = null;
    NotificationService.reset();
    _tickCount           = 0;
    _hasSyncedOnce       = false;
    _consecutiveFailures = 0;
    _offlineSeconds      = 0;
    _isDisconnecting     = false;
    _appBackgrounded     = false;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);

    notifyListeners();
    _syncWithHivemind();
  }

  void _tick(Timer t) {
    if (_isDisconnecting) return;
    // A local clock: poll failures are about the network, not the clock.
    if (_hasSyncedOnce && _remainingSeconds > 0) {
      _remainingSeconds--;
    }

    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _offlineSeconds++;
      if (_offlineSeconds >= _maxOfflineSeconds) {
        _doDisconnect('Server unreachable');
        return;
      }
    }

    if (_hasSyncedOnce && _remainingSeconds <= 0) {
      _doDisconnect('Session expired');
      return;
    }

    _tickCount++;
    final pollInterval = _appBackgrounded
        ? _backgroundPollIntervalSeconds
        : _pollIntervalSeconds;
    if (_tickCount % pollInterval == 0) {
      _syncWithHivemind();
    }

    notifyListeners();

    // Gated on a live tunnel. The plugin cancels the notification when the
    // service stops, and re-posting after that leaves an ongoing notification
    // the user cannot swipe away below Android 14.
    if (_hasSyncedOnce &&
        vpnConnection.status == VpnStatus.connected) {
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
    _hasSyncedOnce = false;
    _lastSyncAt = null;
    NotificationService.reset();
    notifyListeners();

    await vpnConnection.disconnect();

    if (!_isDisconnecting) return;
    _isDisconnecting = false;
    notifyListeners();
  }

  Future<void> _syncWithHivemind() async {
    if (_isDisconnecting || _syncInProgress) return;
    _syncInProgress = true;
    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse(
          '${AppConfig.hivemindApiPublic}/session/status?device_id=$deviceId');
      final response = await HivemindService.directGet(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final bool active = data['active'] ?? false;
        if (!active) {
          await _doDisconnect('Server ended session');
          return;
        }

        _remainingSeconds = data['expires_in_seconds'] ?? _remainingSeconds;
        _usedBytes        = data['used_bytes']        ?? _usedBytes;

        // Measure the real gap between polls: the interval is 5 s in the
        // foreground, 30 s in the background, and arbitrary on a resume sync.
        final now      = DateTime.now();
        final lastSync = _lastSyncAt;
        _lastSyncAt    = now;

        final int deltaBytes = _usedBytes - _lastUsedBytes;
        if (_hasSyncedOnce && deltaBytes > 0 && lastSync != null) {
          final elapsed = now.difference(lastSync).inMilliseconds / 1000.0;
          _currentSpeedKBps =
              elapsed > 0 ? (deltaBytes / elapsed) / 1000 : _currentSpeedKBps;
        } else if (!_hasSyncedOnce) {
          _currentSpeedKBps = 0.0;
        }
        _lastUsedBytes = _usedBytes;

        final capExhausted = data['cap_exhausted'] ?? false;
        if (capExhausted) {
          await _doDisconnect('Data cap reached');
          return;
        }

        _consecutiveFailures = 0;
        _offlineSeconds = 0;
        _hasSyncedOnce = true;
        notifyListeners();
      } else {
        _markSyncFailure();
      }
    } catch (e) {
      debugPrint('Hivemind sync error: $e');
      _markSyncFailure();
    } finally {
      _syncInProgress = false;
    }
  }

  void _markSyncFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners();
    }
  }

  void _resumeTicking() {
    _lastSyncAt = null;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    _syncWithHivemind();
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Keep ticking, but slow the poll — the 5 s one wakes the radio.
      _appBackgrounded = true;
    } else if (state == AppLifecycleState.resumed) {
      _appBackgrounded = false;
      if (_timer != null && _timer!.isActive) {
        _syncWithHivemind();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    super.dispose();
  }
}
