import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/consent_manager.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';

class AdManager extends ChangeNotifier {
  /// Production builds must opt in explicitly with:
  /// --dart-define=ADS_ENABLED=true
  static const bool adsEnabled =
      bool.fromEnvironment('ADS_ENABLED', defaultValue: false);

  static const Duration _loadTimeout = Duration(seconds: 15);
  static const Duration _rewardTimeout = Duration(minutes: 2);

  final Random _secureRandom = Random.secure();

  RewardedAd? _rewardedAd;

  bool _isAdLoaded = false;
  bool get isAdLoaded => adsEnabled && _isAdLoaded;

  bool _isAdLoading = false;
  bool get isAdLoading => adsEnabled && _isAdLoading;

  Completer<bool>? _loadCompleter;

  static String get _adUnitId => AppConfig.adUnitId;

  AdManager() {
    if (adsEnabled && !kIsWeb) preloadAd();
  }

  static Future<bool>? _sdkInit;
  static bool _sdkReady = false;

  static Future<bool> ensureSdkInitialized() async {
    if (!adsEnabled || kIsWeb) return false;
    if (_sdkReady) return true;

    final existing = _sdkInit;
    if (existing != null) return existing;

    final attempt = _initSdk();
    _sdkInit = attempt;

    final ok = await attempt;
    if (ok) {
      _sdkReady = true;
    } else if (identical(_sdkInit, attempt)) {
      // Permit a later retry after a transient consent/network failure.
      _sdkInit = null;
    }
    return ok;
  }

  static Future<bool> _initSdk() async {
    final consentReady = await ConsentManager.requestConsentIfNeeded().timeout(
      const Duration(seconds: 15),
      onTimeout: () => false,
    );

    if (!consentReady) {
      debugPrint('[AdManager] Ads blocked: consent is unresolved.');
      return false;
    }

    try {
      await MobileAds.instance.initialize().timeout(const Duration(seconds: 10));
      return true;
    } catch (e) {
      debugPrint('[AdManager] Mobile Ads initialization failed: $e');
      return false;
    }
  }

  Future<bool> preloadAd() async {
    if (!adsEnabled || kIsWeb) return false;
    if (!await ensureSdkInitialized()) return false;
    if (_isAdLoaded && _rewardedAd != null) return true;
    if (_isAdLoading) {
      final completer = _loadCompleter;
      if (completer == null) return false;
      return await completer.future.timeout(
        _loadTimeout,
        onTimeout: () => false,
      );
    }

    _isAdLoading = true;
    _loadCompleter = Completer<bool>();
    notifyListeners();

    RewardedAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd?.dispose();
          _rewardedAd = ad;
          _isAdLoaded = true;
          _isAdLoading = false;
          notifyListeners();
          if (!(_loadCompleter?.isCompleted ?? true)) {
            _loadCompleter?.complete(true);
          }
        },
        onAdFailedToLoad: (error) {
          debugPrint('[AdManager] Rewarded ad failed to load: ${error.message}');
          _isAdLoaded = false;
          _isAdLoading = false;
          _rewardedAd = null;
          notifyListeners();
          if (!(_loadCompleter?.isCompleted ?? true)) {
            _loadCompleter?.complete(false);
          }
        },
      ),
    );

    return _loadCompleter!.future.timeout(
      _loadTimeout,
      onTimeout: () {
        _isAdLoading = false;
        notifyListeners();
        debugPrint('[AdManager] Rewarded ad load timed out.');
        return false;
      },
    );
  }

  Future<bool> showAd(String adType) async {
    // No fake callbacks or debug session grants. If ads are disabled, reward
    // creation is unavailable by design.
    if (!adsEnabled || kIsWeb) return false;
    if (!await ensureSdkInitialized()) return false;

    if (!_isAdLoaded || _rewardedAd == null) {
      final loaded = await preloadAd();
      if (!loaded || _rewardedAd == null) {
        debugPrint('[AdManager] Cannot show ad: load failed.');
        return false;
      }
    }

    final deviceId = await CryptoService.getDeviceId();
    final nonce = _newNonce();
    HivemindService.setExpectedNonce(nonce);

    final ad = _rewardedAd!;
    final rewardCompleter = Completer<bool>();
    var rewardEarned = false;

    ad.setServerSideOptions(
      ServerSideVerificationOptions(
        customData: jsonEncode({
          'device_id': deviceId,
          'ad_type': adType,
          'nonce': nonce,
        }),
      ),
    );

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        debugPrint('[AdManager] Rewarded ad showing.');
      },
      onAdDismissedFullScreenContent: (shownAd) {
        shownAd.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        notifyListeners();

        if (!rewardEarned) {
          HivemindService.clearExpectedNonce();
          if (!rewardCompleter.isCompleted) rewardCompleter.complete(false);
        }

        preloadAd();
      },
      onAdFailedToShowFullScreenContent: (failedAd, error) {
        debugPrint('[AdManager] Rewarded ad failed to show: $error');
        failedAd.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        HivemindService.clearExpectedNonce();
        notifyListeners();
        if (!rewardCompleter.isCompleted) rewardCompleter.complete(false);
      },
    );

    try {
      await ad.show(
        onUserEarnedReward: (AdWithoutView _, RewardItem reward) {
          debugPrint(
            '[AdManager] SDK reward callback: ${reward.amount} ${reward.type}',
          );
          rewardEarned = true;
          if (!rewardCompleter.isCompleted) rewardCompleter.complete(true);
        },
      );
    } catch (e) {
      debugPrint('[AdManager] Rewarded ad show threw: $e');
      HivemindService.clearExpectedNonce();
      _isAdLoaded = false;
      _rewardedAd = null;
      ad.dispose();
      notifyListeners();
      return false;
    }

    final rewarded = await rewardCompleter.future.timeout(
      _rewardTimeout,
      onTimeout: () {
        debugPrint('[AdManager] Reward callback timed out.');
        HivemindService.clearExpectedNonce();
        return false;
      },
    );

    if (!rewarded) HivemindService.clearExpectedNonce();
    return rewarded;
  }

  String _newNonce() {
    final bytes = List<int>.generate(18, (_) => _secureRandom.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  @override
  void dispose() {
    _rewardedAd?.dispose();
    super.dispose();
  }
}
