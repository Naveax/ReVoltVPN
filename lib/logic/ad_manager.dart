import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:paladinvpn/logic/crypto_service.dart';
import 'package:paladinvpn/logic/hivemind_service.dart';
import 'package:paladinvpn/logic/app_config.dart';

/// AdManager manages the lifecycle of rewarded video ads.
///
/// When [adsEnabled] is false (pre-launch mode) all ad operations are
/// silently skipped — the app connects without any ad requirement.
class AdManager extends ChangeNotifier {
  /// Flip to `true` after Google Play launch when real ads are wired up.
  static const bool adsEnabled = false;

  RewardedAd? _rewardedAd;

  bool _isAdLoaded = false;
  bool get isAdLoaded => adsEnabled ? _isAdLoaded : true;

  bool _isAdLoading = false;
  bool get isAdLoading => adsEnabled ? _isAdLoading : false;

  Completer<bool>? _loadCompleter;

  // Google-provided test ad unit
  static String get _adUnitId => AppConfig.adUnitId;

  AdManager() {
    if (adsEnabled) preloadAd();
  }

  /// Loads a rewarded ad in the background and returns a Future when ready.
  /// Safe to call multiple times — re-entrant calls wait on the same load.
  /// No-op when [adsEnabled] is false.
  Future<bool> preloadAd() async {
    if (!adsEnabled) return true;
    // If already loaded, return instantly
    if (_isAdLoaded) return true;
    
    // If we're already loading one right now, wait for that same request to finish
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

  /// Displays the rewarded video ad to the user.
  /// Returns false immediately when [adsEnabled] is false.
  Future<bool> showAd(String adType) async {
    if (!adsEnabled) return false;

    // 1. Ensure the ad is fully loaded before trying to show it
    if (!_isAdLoaded || _rewardedAd == null) {
      final loaded = await preloadAd();
      if (!loaded || _rewardedAd == null) {
        debugPrint('[AdManager] Cannot show ad, failed to load.');
        return false;
      }
    }

    // 2. Fetch device credentials for Server-Side Verification (SSV)
    final deviceId = await CryptoService.getDeviceId();
    final keys = await CryptoService.getOrCreateKeys();
    final pubKey = keys['publicKey']!;

    // 3. Generate a connect nonce so the subsequent poll can verify
    //    it's talking to the session created by *this* ad.
    final nonce = '${Random().nextInt(0x7FFFFFFF)}-${DateTime.now().millisecondsSinceEpoch}';
    HivemindService.setExpectedNonce(nonce);
    debugPrint('[AdManager] Ad nonce: $nonce');

    // 4. Build SSV options to send to our Hivemind server via Google's callback
    final ssvOptions = ServerSideVerificationOptions(
      customData: jsonEncode({
        'device_id': deviceId,
        'public_key': pubKey,
        'ad_type': adType,
        'nonce': nonce,
      }),
    );

    Completer<bool> rewardCompleter = Completer<bool>();

    // 4. Setup full screen callbacks to handle dismissal and errors
    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) => debugPrint('[AdManager] Ad showing.'),
      onAdDismissedFullScreenContent: (ad) {
        debugPrint('[AdManager] Ad dismissed.');
        ad.dispose();
        _isAdLoaded = false;
        _rewardedAd = null;
        // Start loading the next ad immediately
        preloadAd();
        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(false); // User closed before earning reward
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

    // 5. Show the ad with SSV options
    _rewardedAd!.setServerSideOptions(ssvOptions);
    await _rewardedAd!.show(
      onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
        debugPrint('[AdManager] Reward earned: ${reward.amount} ${reward.type}');
        // The SSV callback will hit our server independently. We just need to signal the UI
        // that the ad was successfully completed.
        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(true);
        }
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
