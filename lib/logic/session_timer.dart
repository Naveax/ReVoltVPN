import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/vpn_connection.dart';
import 'package:revoltvpn/logic/crypto_service.dart';

class SessionTimer extends ChangeNotifier {
  Timer? _timer;
  int _tickCount = 0;

  final VpnConnection vpnConnection;

  int _remainingSeconds = 0;
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
  static const int _maxOfflineSeconds = 120;
  int _offlineSeconds = 0;

  static const int _pollIntervalSeconds = 5;

  int _lastUsedBytes = 0;
  DateTime? _lastSuccessfulSyncAt;
  double _currentSpeedKBps = 0.0;

  SessionTimer({required this.vpnConnection}) {
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
    bool claimed = false;
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

    final hadActiveSession = isRunning || _hasSyncedOnce;
    if (!hadActiveSession || _isDisconnecting) return;

    if (vpnConnection.status == VpnStatus.error) {
      // VpnConnection already cleans up failed runtimes. Do not call
      // disconnect() again here or the useful error state/message gets erased.
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
    _hasSyncedOnce = false;
    _lastSuccessfulSyncAt = null;
    _consecutiveFailures = 0;
    _offlineSeconds = 0;
    notifyListeners();
  }

  Future<void> start() async {
    _remainingSeconds = 0;
    _usedBytes = 0;
    _lastUsedBytes = 0;
    _lastSuccessfulSyncAt = null;
    _currentSpeedKBps = 0.0;
    _tickCount = 0;
    _hasSyncedOnce = false;
    _consecutiveFailures = 0;
    _offlineSeconds = 0;
    _isDisconnecting = false;

    // This is a genuinely new VPN session, so the one-support-reward allowance
    // starts fresh. Increment the epoch so a stale async storage load from app
    // startup cannot overwrite the new-session state.
    _supportStateEpoch++;
    _supportRewardClaimed = false;
    _supportRewardStateLoaded = true;
    unawaited(_persistSupportRewardState(false));

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);

    notifyListeners();
    _syncWithHivemind();
  }

  void _tick(Timer t) {
    if (_isDisconnecting) return;
    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;
      }
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
    if (_tickCount % _pollIntervalSeconds == 0) {
      _syncWithHivemind();
    }

    notifyListeners();
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
    _lastSuccessfulSyncAt = null;
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
          // A malformed HTTP 200 payload is not an authoritative command to
          // tear down a healthy VPN. Count it as a sync failure instead.
          debugPrint('[Timer] Session payload missing boolean active state.');
          _markSyncFailure();
          return;
        }
        if (!activeValue) {
          // Explicit server revocation remains authoritative.
          await _doDisconnect('Server ended session');
          return;
        }

        final expiresValue = data['expires_in_seconds'];
        if (expiresValue is! num ||
            !expiresValue.isFinite ||
            expiresValue < 0) {
          // Do not turn a missing/malformed TTL into zero and disconnect one
          // tick later. Only a real zero returned by the server means expiry.
          debugPrint('[Timer] Session payload has invalid expiry.');
          _markSyncFailure();
          return;
        }
        _remainingSeconds = expiresValue.toInt();
        _usedBytes = _readNonNegativeInt(data['used_bytes'], _usedBytes);

        final now = DateTime.now();
        final previousSyncAt = _lastSuccessfulSyncAt;
        final int deltaBytes = _usedBytes - _lastUsedBytes;
        if (_hasSyncedOnce && previousSyncAt != null) {
          final elapsedMs = now.difference(previousSyncAt).inMilliseconds;
          if (deltaBytes > 0 && elapsedMs > 0) {
            _currentSpeedKBps = (deltaBytes / (elapsedMs / 1000.0)) / 1000.0;
          } else {
            _currentSpeedKBps = 0.0;
          }
        } else {
          _currentSpeedKBps = 0.0;
        }
        _lastUsedBytes = _usedBytes;
        _lastSuccessfulSyncAt = now;

        final capExhausted = data['cap_exhausted'] == true;
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
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners();
    }
  }

  void _resumeTicking() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    _syncWithHivemind();
    notifyListeners();
  }

  @override
  void dispose() {
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    super.dispose();
  }
}
