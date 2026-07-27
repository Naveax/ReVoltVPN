import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/components/notification.dart';

class SessionTimer extends ChangeNotifier {
  Timer? _timer;
  int _tickCount = 0;

  final VpnConnection vpnConnection;

  int _remainingSeconds = 0;
  int _usedBytes       = 0;

  bool _hasSyncedOnce       = false;
  int  _consecutiveFailures = 0;
  bool _isDisconnecting     = false;
  bool _userInitiatedStop   = false;

  bool _isThrottled         = false;

  int? _currentPort;
  bool _portSwitchInProgress = false;

  static const int _maxConsecutiveFailures = 3;

  static const int _maxOfflineSeconds = 120;
  int _offlineSeconds = 0;

  static const int _pollIntervalSeconds = 5;

  int    _lastUsedBytes     = 0;
  double _currentSpeedKBps  = 0.0;

  String _lastNotifTime  = '';
  String _lastNotifSpeed = '';

  SessionTimer({required this.vpnConnection}) {
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

  // Lifecycle

  /// Fires whenever VpnConnection state changes.
  void _onVpnConnectionChanged() {

    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        vpnConnection.isStartupRestoration) {
      start('resume');
      return;
    }


    // The underlying VLESS tunnel may briefly flap.  If we weren't
    // explicitly stopped by the user, resume where we left off.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_userInitiatedStop &&
        _hasSyncedOnce) {
      debugPrint('[Timer] VPN reconnected after blip — resuming.');
      _resumeTicking();
      return;
    }


    if (vpnConnection.status == VpnStatus.disconnected && isRunning) {
      _stopInternal();
    }
  }

  Future<void> start() async {
    _remainingSeconds    = 0;
    _usedBytes           = 0;
    _lastUsedBytes       = 0;
    _currentSpeedKBps    = 0.0;
    _tickCount           = 0;
    _hasSyncedOnce       = false;
    _consecutiveFailures = 0;
    _offlineSeconds      = 0;
    _isDisconnecting     = false;
    _userInitiatedStop   = false;
    _currentPort         = null;
    _portSwitchInProgress = false;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);

    notifyListeners();

    // Kick off the first sync — the UI will show real data as soon as it lands.
    _syncWithHivemind();
  }

  void _tick(Timer t) {

    // Decrement the local clock as long as we're not in a network blackout.
    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;
      }
    }


    // If the server has been unreachable for too long, kill the VPN.
    // Don't let an orphaned tunnel keep running forever.
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _offlineSeconds++;
      if (_offlineSeconds >= _maxOfflineSeconds) {
        debugPrint('[Timer] Offline for $_maxOfflineSeconds s — forcing disconnect.');
        _forceDisconnect('Session lost — server unreachable');
        return;
      }
    }


    // When our clock hits zero, disconnect immediately.  Don't wait for the
    // next server poll — the session is over and the user expects the VPN
    // to drop right now.
    if (_hasSyncedOnce && _remainingSeconds <= 0) {
      debugPrint('[Timer] Local countdown expired — disconnecting.');
      _forceDisconnect('Session expired');
      return;
    }

    _tickCount++;
    if (_tickCount % _pollIntervalSeconds == 0) {
      _syncWithHivemind();
    }


    // Uses the locally-decremented time so the notification stays in sync
    // with the in-app display, not gated behind the 5 s server poll.
    if (_hasSyncedOnce) {
      final speedText = _currentSpeedKBps > 0.5
          ? '${_currentSpeedKBps.toStringAsFixed(1)} KB/s'
          : 'Idle';
      if (formatted != _lastNotifTime || speedText != _lastNotifSpeed) {
        _lastNotifTime  = formatted;
        _lastNotifSpeed = speedText;
        VpnNotificationManager.showOrUpdateStatus(
          timeLeft: formatted,
          speedKbps: speedText,
        );
      }
    }

    notifyListeners();
  }

  void _forceDisconnect(String reason) {
    if (_isDisconnecting) return; // Already tearing down
    debugPrint('[Timer] $reason — forcing disconnect.');
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _isDisconnecting = true;
    VpnNotificationManager.cancel();
    notifyListeners();
    // Await the disconnect so the tunnel is confirmed down before we
    // consider the session fully cleaned up.
    vpnConnection.disconnect();
  }



  Future<void> _syncWithHivemind() async {
    // Never sync while the user is explicitly disconnecting.
    if (_isDisconnecting) return;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse(
          '${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final bool active = data['active'] ?? false;
        if (!active) {
          // Server killed the session — tear down and wait for it.
          stop();
          await vpnConnection.disconnect();
          return;
        }

        _remainingSeconds = data['expires_in_seconds'] ?? _remainingSeconds;
        _usedBytes        = data['used_bytes']        ?? _usedBytes;


        final int deltaBytes = _usedBytes - _lastUsedBytes;
        if (_hasSyncedOnce && deltaBytes > 0) {
          _currentSpeedKBps = (deltaBytes / _pollIntervalSeconds) / 1000;
        } else if (!_hasSyncedOnce) {
          _currentSpeedKBps = 0.0;
        }
        _lastUsedBytes = _usedBytes;


        // ── Detect port change (throttle engage / disengage) ──────
        final serverPort = data['vless_port'];
        if (serverPort != null &&
            _currentPort != null &&
            serverPort != _currentPort &&
            !_portSwitchInProgress) {
          debugPrint('[Timer] Port changed $_currentPort → $serverPort — reconnecting…');
          _currentPort = serverPort;
          _isThrottled = data['is_throttled'] ?? false;
          _portSwitchInProgress = true;

          _timer?.cancel();
          _isDisconnecting = true;
          await vpnConnection.disconnect(skipCleanup: true);
          await vpnConnection.connect(skipAdBypass: true, quickReconnect: true);

          _resumeTicking();
          _portSwitchInProgress = false;
          return;
        }
        _currentPort = serverPort;
        _isThrottled = data['is_throttled'] ?? false;

        _consecutiveFailures = 0;
        _offlineSeconds = 0;
        _hasSyncedOnce = true;

        notifyListeners();
      } else if (response.statusCode == 404) {
        // Peer not found on server (expired / deleted natively)
        stop();
        await vpnConnection.disconnect();
      } else {
        _markSyncFailure();
      }
    } catch (e) {
      debugPrint('Hivemind sync error: $e');
      _markSyncFailure();
    }
  }

  void _markSyncFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners(); // let the UI show "Reconnecting…"
    }
  }



  void stop() {
    _userInitiatedStop = true;
    _isDisconnecting = true;
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _hasSyncedOnce = false;
    _remainingSeconds = 0;
    notifyListeners();
  }

  void _resumeTicking() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    _syncWithHivemind();
    notifyListeners();
  }

  void _stopInternal() {
    _isDisconnecting = true;
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _hasSyncedOnce = false;
    VpnNotificationManager.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    VpnNotificationManager.cancel();
    super.dispose();
  }
}
