import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/consent_manager.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

class AdManager extends ChangeNotifier {
  static const bool adsEnabled = false;

  RewardedAd? _rewardedAd;

  bool _isAdLoaded = false;
  bool get isAdLoaded => adsEnabled ? _isAdLoaded : true;

  bool _isAdLoading = false;
  bool get isAdLoading => adsEnabled ? _isAdLoading : false;

  Completer<bool>? _loadCompleter;
  Future<bool>? _showInFlight;
  String? _showInFlightType;

  static String get _adUnitId => AppConfig.adUnitId;

  AdManager() {
    if (adsEnabled) preloadAd();
  }

  static Future<void>? _sdkInit;
  static Future<void> ensureSdkInitialized() {
    if (!adsEnabled) return Future.value();
    return _sdkInit ??= _initSdk();
  }

  static Future<void> _initSdk() async {
    try {
      await ConsentManager.requestConsentIfNeeded()
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[AdManager] Consent init skipped: $e');
    }
    try {
      await MobileAds.instance.initialize().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[AdManager] MobileAds init skipped: $e');
    }
  }

  Future<bool> preloadAd() async {
    if (!adsEnabled) return true;
    await ensureSdkInitialized();
    if (_isAdLoaded) return true;
    if (_isAdLoading) return _loadCompleter?.future ?? Future.value(false);

    _isAdLoading = true;
    _loadCompleter = Completer<bool>();
    notifyListeners();

    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 500));
      _isAdLoaded = true;
      _isAdLoading = false;
      notifyListeners();
      _loadCompleter?.complete(true);
      return true;
    }

    RewardedAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd = ad;
          _isAdLoaded = true;
          _isAdLoading = false;
          notifyListeners();
          if (!(_loadCompleter?.isCompleted ?? true)) {
            _loadCompleter?.complete(true);
          }
        },
        onAdFailedToLoad: (error) {
          debugPrint('Rewarded ad failed to load: ${error.message}');
          _isAdLoaded = false;
          _isAdLoading = false;
          notifyListeners();
          if (!(_loadCompleter?.isCompleted ?? true)) {
            _loadCompleter?.complete(false);
          }
        },
      ),
    );

    return _loadCompleter!.future;
  }

  /// Rewarded-ad state is intentionally single-flight. Two concurrent main
  /// flows could otherwise stage different possession candidates for the same
  /// device before either Google SSV callback arrives. A duplicate request for
  /// the same reward intent shares the operation; a different intent fails
  /// closed instead of inheriting another ad's result.
  Future<bool> showAd(String adType) {
    final existing = _showInFlight;
    if (existing != null) {
      return _showInFlightType == adType
          ? existing
          : Future<bool>.value(false);
    }

    late final Future<bool> tracked;
    tracked = _showAdInner(adType).whenComplete(() {
      if (identical(_showInFlight, tracked)) {
        _showInFlight = null;
        _showInFlightType = null;
      }
    });
    _showInFlight = tracked;
    _showInFlightType = adType;
    return tracked;
  }

  Future<bool> _showAdInner(String adType) async {
    if (adType != 'main' && adType != 'support') {
      debugPrint('[AdManager] Rejected unknown ad type.');
      return false;
    }

    String nonce;
    if (adType == 'main') {
      if (!await HivemindService.retryPendingSessionStop()) {
        debugPrint('[AdManager] Server session revocation is still pending.');
        return false;
      }

      final existing = await HivemindService.probeCurrentSession();
      if (existing == SessionProbeResult.active) {
        final currentNonce = await HivemindService.getSessionNonce();
        if (currentNonce != null) {
          await _clearRecoveredCandidate(currentNonce);
        }
        return true;
      }
      if (existing == SessionProbeResult.unavailable) {
        return false;
      }

      // A Google SSV callback can arrive after the bounded foreground poll or
      // after process death. Reuse the durable pending candidate before ever
      // minting another nonce, otherwise a late callback could create a live
      // generation the client no longer possesses and the server would
      // correctly reject a different nonce as LiveSessionNonceMismatch.
      final pending = await CryptoService.getPendingMainSessionNonce();
      if (pending != null) {
        if (await _confirmMainCandidate(pending)) return true;
        nonce = pending;
      } else {
        nonce = HivemindService.newNonce();
      }
    } else {
      if (await HivemindService.probeCurrentSession() !=
          SessionProbeResult.active) {
        return false;
      }
      final currentNonce = await HivemindService.getSessionNonce();
      if (currentNonce == null) return false;
      nonce = currentNonce;
    }

    // Debug-only compatibility callback. Stage the main candidate before the
    // request for the same crash-safety rule used by production SSV.
    if (!adsEnabled && kDebugMode) {
      final deviceId = await CryptoService.getDeviceId();
      try {
        if (adType == 'main') {
          await CryptoService.setPendingMainSessionNonce(nonce);
        }
        final customData = jsonEncode({
          'device_id': deviceId,
          'ad_type': adType,
          'nonce': nonce,
        });
        final fakeUrl = Uri.parse(
          '${AppConfig.hivemindApiPublic}/admob/callback'
          '?signature=test&key_id=test'
          '&custom_data=${Uri.encodeComponent(customData)}',
        );
        final response = await HivemindService.directGet(
          fakeUrl,
          timeout: const Duration(seconds: 8),
        );
        if (response.statusCode != 200) return false;
        if (adType == 'main') {
          return _confirmMainCandidate(nonce);
        }
        return true;
      } catch (_) {
        return false;
      }
    }

    if (!adsEnabled) return false;

    await ensureSdkInitialized();
    if (!_isAdLoaded || _rewardedAd == null) {
      final loaded = await preloadAd();
      if (!loaded || _rewardedAd == null) {
        debugPrint('[AdManager] Cannot show ad, failed to load.');
        return false;
      }
    }

    final deviceId = await CryptoService.getDeviceId();
    if (adType == 'main') {
      try {
        // Persist before custom_data is handed to the SDK. If the process dies
        // after Google receives the ad event, the same candidate remains
        // recoverable and will be reused rather than silently abandoned.
        await CryptoService.setPendingMainSessionNonce(nonce);
      } catch (e) {
        debugPrint('[AdManager] Could not persist SSV candidate: $e');
        return false;
      }
    }

    final ssvOptions = ServerSideVerificationOptions(
      customData: jsonEncode({
        'device_id': deviceId,
        'ad_type': adType,
        'nonce': nonce,
      }),
    );

    final rewardCompleter = Completer<bool>();

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) =>
          debugPrint('[AdManager] Ad showing.'),
      onAdDismissedFullScreenContent: (ad) {
        debugPrint('[AdManager] Ad dismissed.');
        ad.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        preloadAd();
        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(false);
        }
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdManager] Ad failed to show: $error');
        ad.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(false);
        }
      },
    );

    _rewardedAd!.setServerSideOptions(ssvOptions);
    await _rewardedAd!.show(
      onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
        debugPrint(
          '[AdManager] Reward earned: ${reward.amount} ${reward.type}',
        );
        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(true);
        }
      },
    );

    final earned = await rewardCompleter.future;
    if (!earned) {
      // Do not erase a staged main candidate here. A previous/reused attempt
      // may already have a valid delayed SSV callback in flight. Reusing the
      // candidate on the next ad is harmless; forgetting it can orphan a live
      // server generation.
      return false;
    }

    if (adType == 'main') {
      return _confirmMainCandidate(nonce);
    }
    return true;
  }

  Future<bool> _confirmMainCandidate(String nonce) async {
    final confirmed = await HivemindService.confirmAndSetSessionNonce(nonce);
    if (confirmed) {
      await _clearRecoveredCandidate(nonce);
    }
    return confirmed;
  }

  Future<void> _clearRecoveredCandidate(String nonce) async {
    try {
      await CryptoService.clearPendingMainSessionNonceIfMatches(nonce);
    } catch (e) {
      // Authorization is already server-confirmed at this point. A stale
      // candidate is safe because future cleanup compares the exact nonce.
      debugPrint('[AdManager] Pending SSV candidate cleanup deferred: $e');
    }
  }

  @override
  void dispose() {
    _rewardedAd?.dispose();
    super.dispose();
  }
}
