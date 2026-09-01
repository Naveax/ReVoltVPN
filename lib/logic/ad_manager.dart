import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/consent_manager.dart';

class AdManager extends ChangeNotifier {
  /// Debug builds use the server's explicit test callback. Release builds use
  /// real rewarded ads and SSV. A release must never silently fall back to the
  /// test bypass path.
  static bool get adsEnabled => kReleaseMode;

  RewardedAd? _rewardedAd;

  bool _isAdLoaded = false;
  bool get isAdLoaded => adsEnabled ? _isAdLoaded : true;

  bool _isAdLoading = false;
  bool get isAdLoading => adsEnabled ? _isAdLoading : false;

  Completer<bool>? _loadCompleter;

  static String get _adUnitId => AppConfig.adUnitId;

  AdManager() {
    if (adsEnabled) {
      unawaited(preloadAd());
    }
  }

  static Future<void>? _sdkInit;

  static Future<void> ensureSdkInitialized() async {
    final existing = _sdkInit;
    if (existing != null) {
      await existing;
      return;
    }

    final init = _initSdk();
    _sdkInit = init;
    try {
      await init;
    } catch (_) {
      if (identical(_sdkInit, init)) _sdkInit = null;
      rethrow;
    }
  }

  static Future<void> _initSdk() async {
    final consentResolved = await ConsentManager.requestConsentIfNeeded()
        .timeout(const Duration(seconds: 15));
    if (!consentResolved) {
      throw StateError('Ad consent is unresolved.');
    }

    await MobileAds.instance.initialize().timeout(const Duration(seconds: 10));
  }

  Future<bool> preloadAd() async {
    if (!adsEnabled) return true;
    if (_isAdLoaded) return true;
    if (_isAdLoading) return _loadCompleter?.future ?? Future.value(false);

    _isAdLoading = true;
    _loadCompleter = Completer<bool>();
    notifyListeners();

    try {
      await ensureSdkInitialized();
    } catch (e) {
      debugPrint('[AdManager] Refusing ad load before consent/SDK init: $e');
      _isAdLoading = false;
      _isAdLoaded = false;
      notifyListeners();
      if (!(_loadCompleter?.isCompleted ?? true)) {
        _loadCompleter?.complete(false);
      }
      return false;
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
          debugPrint('[AdManager] Rewarded ad failed to load: ${error.message}');
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

  Future<bool> showAd(String adType) async {
    if (!adsEnabled && kDebugMode) {
      final deviceId = await CryptoService.getDeviceId();
      final nonce = HivemindService.createNonce();
      HivemindService.setExpectedNonce(nonce);
      try {
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
        return response.statusCode >= 200 && response.statusCode < 300;
      } catch (_) {
        return false;
      }
    }

    if (!adsEnabled) return false;

    if (!_isAdLoaded || _rewardedAd == null) {
      final loaded = await preloadAd();
      if (!loaded || _rewardedAd == null) {
        debugPrint('[AdManager] Cannot show ad; load did not complete.');
        return false;
      }
    }

    final deviceId = await CryptoService.getDeviceId();
    final nonce = HivemindService.createNonce();
    HivemindService.setExpectedNonce(nonce);

    _rewardedAd!.setServerSideOptions(
      ServerSideVerificationOptions(
        customData: jsonEncode({
          'device_id': deviceId,
          'ad_type': adType,
          'nonce': nonce,
        }),
      ),
    );

    final rewardCompleter = Completer<bool>();

    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        unawaited(preloadAd());
        if (!rewardCompleter.isCompleted) rewardCompleter.complete(false);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdManager] Ad failed to show: $error');
        ad.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        if (!rewardCompleter.isCompleted) rewardCompleter.complete(false);
      },
    );

    await _rewardedAd!.show(
      onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
        if (!rewardCompleter.isCompleted) rewardCompleter.complete(true);
      },
    );

    return rewardCompleter.future;
  }

  @override
  void dispose() {
    _rewardedAd?.dispose();
    super.dispose();
  }
}
