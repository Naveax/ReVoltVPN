import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:paladinvpn/logic/crypto_service.dart';
import 'package:paladinvpn/logic/hivemind_service.dart';
import 'package:paladinvpn/logic/app_config.dart';

/// AdManager manages the lifecycle of rewarded video ads.
/// 
/// It acts as a strict gatekeeper: users MUST watch an ad to connect.
/// If an ad is not ready when they click connect, it forces them to wait
/// while it loads. If they dismiss the ad early, they do not get the connection.
class AdManager extends ChangeNotifier {
  RewardedAd? _rewardedAd;
  
  bool _isAdLoaded = false;
  bool get isAdLoaded => _isAdLoaded;

  bool _isAdLoading = false;
  bool get isAdLoading => _isAdLoading;

  Completer<bool>? _loadCompleter;

  // Google-provided test ad unit
  static String get _adUnitId => AppConfig.adUnitId;

  AdManager() {
    _preloadAd();
  }

  /// Internal helper to load an ad and return a Future when it's ready
  Future<bool> _preloadAd() async {
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
  Future<bool> showAd(String adType) async {
    // 1. Ensure the ad is fully loaded before trying to show it
    if (!_isAdLoaded || _rewardedAd == null) {
      final loaded = await _preloadAd();
      if (!loaded || _rewardedAd == null) {
        debugPrint('[AdManager] Cannot show ad, failed to load.');
        return false;
      }
    }

    // 2. Fetch device credentials for Server-Side Verification (SSV)
    final deviceId = await CryptoService.getDeviceId();
    final keys = await CryptoService.getOrCreateKeys();
    final pubKey = keys['publicKey']!;

    // 3. Build SSV options to send to our Hivemind server via Google's callback
    final ssvOptions = ServerSideVerificationOptions(
      customData: jsonEncode({
        'device_id': deviceId,
        'public_key': pubKey,
        'ad_type': adType,
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
        _preloadAd();
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
