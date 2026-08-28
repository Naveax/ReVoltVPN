import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/consent_manager.dart';

class AdManager extends ChangeNotifier {
  /// Release builds enable real ads by default. Debug builds can opt in with
  /// --dart-define=ADS_ENABLED=true.
  static const bool adsEnabled = bool.fromEnvironment(
    'ADS_ENABLED',
    defaultValue: kReleaseMode,
  );

  /// The fake callback exists only for explicitly configured debug builds.
  /// kDebugMode is a compile-time constant, so release builds cannot enter it.
  static const bool _allowDebugBypass = bool.fromEnvironment(
    'ALLOW_AD_DEBUG_BYPASS',
    defaultValue: false,
  );

  static bool get debugBypassEnabled => kDebugMode && _allowDebugBypass;

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

  static Future<bool> ensureSdkInitialized() async {
    if (!adsEnabled || kIsWeb) return false;

    final existing = _sdkInit;
    if (existing != null) return existing;

    final init = _initSdk();
    _sdkInit = init;

    final ok = await init;
    if (!ok && identical(_sdkInit, init)) {
      // Permit a later retry after transient UMP/network failures.
      _sdkInit = null;
    }
    return ok;
  }

  static Future<bool> _initSdk() async {
    final consentOk = await ConsentManager.requestConsentIfNeeded().timeout(
      const Duration(minutes: 3),
      onTimeout: () => false,
    );

    if (!consentOk) {
      debugPrint('[AdManager] Mobile Ads blocked by unresolved consent.');
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
    if (_isAdLoading) return _loadCompleter?.future ?? Future.value(false);

    _isAdLoading = true;
    final completer = Completer<bool>();
    _loadCompleter = completer;
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
          if (!completer.isCompleted) completer.complete(true);
        },
        onAdFailedToLoad: (error) {
          debugPrint('[AdManager] Rewarded ad failed to load: ${error.message}');
          _rewardedAd = null;
          _isAdLoaded = false;
          _isAdLoading = false;
          notifyListeners();
          if (!completer.isCompleted) completer.complete(false);
        },
      ),
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _isAdLoading = false;
        _isAdLoaded = false;
        notifyListeners();
        return false;
      },
    );
  }

  /// Shows a rewarded ad and returns true only after both:
  /// 1. Google SDK reports the local reward event, and
  /// 2. Hivemind reports an active session with the exact SSV nonce.
  Future<bool> showAd(String adType) async {
    if (!adsEnabled) {
      if (debugBypassEnabled) {
        return _runDebugBypass(adType);
      }

      debugPrint(
        '[AdManager] Ads are disabled. Release sessions fail closed; '
        'enable ADS_ENABLED for real rewarded sessions.',
      );
      return false;
    }

    if (kIsWeb || !await ensureSdkInitialized()) return false;

    if (!_isAdLoaded || _rewardedAd == null) {
      final loaded = await preloadAd();
      if (!loaded || _rewardedAd == null) {
        debugPrint('[AdManager] Cannot show ad; no rewarded ad is loaded.');
        return false;
      }
    }

    final deviceId = await CryptoService.getDeviceId();
    final nonce = HivemindService.createSessionNonce();
    HivemindService.setExpectedNonce(nonce);

    final ssvOptions = ServerSideVerificationOptions(
      customData: jsonEncode({
        'device_id': deviceId,
        'ad_type': adType,
        'nonce': nonce,
      }),
    );

    final ad = _rewardedAd!;
    final rewardCompleter = Completer<bool>();

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (_) {
        debugPrint('[AdManager] Rewarded ad showing.');
      },
      onAdDismissedFullScreenContent: (shownAd) {
        shownAd.dispose();
        if (identical(_rewardedAd, shownAd)) {
          _rewardedAd = null;
          _isAdLoaded = false;
        }
        _isAdLoading = false;
        notifyListeners();
        preloadAd();

        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(false);
        }
      },
      onAdFailedToShowFullScreenContent: (shownAd, error) {
        debugPrint('[AdManager] Rewarded ad failed to show: $error');
        shownAd.dispose();
        if (identical(_rewardedAd, shownAd)) {
          _rewardedAd = null;
          _isAdLoaded = false;
        }
        _isAdLoading = false;
        notifyListeners();
        preloadAd();

        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(false);
        }
      },
    );

    try {
      // SSV custom data must be attached before the ad is shown.
      await ad
          .setServerSideOptions(ssvOptions)
          .timeout(const Duration(seconds: 5));

      await ad.show(
        onUserEarnedReward: (AdWithoutView _, RewardItem reward) {
          debugPrint(
            '[AdManager] Local reward event: ${reward.amount} ${reward.type}; '
            'waiting for server-side verification.',
          );
          if (!rewardCompleter.isCompleted) {
            rewardCompleter.complete(true);
          }
        },
      );

      final locallyEarned = await rewardCompleter.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => false,
      );

      if (!locallyEarned) {
        HivemindService.clearExpectedNonce(nonce);
        return false;
      }

      final serverVerified = await HivemindService.waitForSessionActivation(
        expectedNonce: nonce,
        timeout: const Duration(seconds: 25),
      );

      if (!serverVerified) {
        debugPrint('[AdManager] SSV callback was not verified in time.');
        HivemindService.clearExpectedNonce(nonce);
        return false;
      }

      // Main-session config fetch consumes this nonce. Support rewards do not.
      if (adType != 'main') {
        HivemindService.clearExpectedNonce(nonce);
      }

      return true;
    } catch (e) {
      debugPrint('[AdManager] Rewarded flow failed closed: $e');
      HivemindService.clearExpectedNonce(nonce);
      return false;
    }
  }

  Future<bool> _runDebugBypass(String adType) async {
    assert(kDebugMode);

    final deviceId = await CryptoService.getDeviceId();
    final nonce = HivemindService.createSessionNonce();
    HivemindService.setExpectedNonce(nonce);

    try {
      final customData = jsonEncode({
        'device_id': deviceId,
        'ad_type': adType,
        'nonce': nonce,
      });

      final endpoint = Uri.parse('${AppConfig.hivemindApiPublic}/admob/callback');
      final fakeUrl = endpoint.replace(
        queryParameters: {
          ...endpoint.queryParameters,
          'signature': 'test',
          'key_id': 'test',
          'custom_data': customData,
        },
      );

      final response = await HivemindService.directGet(
        fakeUrl,
        timeout: const Duration(seconds: 8),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        HivemindService.clearExpectedNonce(nonce);
        return false;
      }

      final verified = await HivemindService.waitForSessionActivation(
        expectedNonce: nonce,
        timeout: const Duration(seconds: 15),
      );

      if (!verified || adType != 'main') {
        HivemindService.clearExpectedNonce(nonce);
      }

      return verified;
    } catch (e) {
      debugPrint('[AdManager] Explicit debug bypass failed: $e');
      HivemindService.clearExpectedNonce(nonce);
      return false;
    }
  }

  @override
  void dispose() {
    _rewardedAd?.dispose();
    _rewardedAd = null;
    super.dispose();
  }
}
