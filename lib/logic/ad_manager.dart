import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/consent_manager.dart';

class AdManager extends ChangeNotifier {
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

  // ── Show ad (or debug bypass) ─────────────────────────────────────

  Future<bool> showAd(String adType) async {
    // Never let an unknown UI/client value fall into the privileged main reward path.
    if (adType != 'main' && adType != 'support') {
      debugPrint('[AdManager] Rejected unknown ad type.');
      return false;
    }

    String nonce;
    if (adType == 'main') {
      // If a previous user-requested disconnect still has an ambiguous server revocation,
      // do not mint a new main nonce. Replacing a possibly-live generation must fail closed.
      if (!await HivemindService.retryPendingSessionStop()) {
        debugPrint('[AdManager] Server session revocation is still pending.');
        return false;
      }

      final existing = await HivemindService.probeCurrentSession();
      if (existing == SessionProbeResult.active) {
        // The user already owns a live server session. Reuse that entitlement rather than
        // watching another ad whose different nonce the hardened server will reject.
        return true;
      }
      if (existing == SessionProbeResult.unavailable) {
        return false;
      }
      nonce = HivemindService.newNonce();
    } else {
      // Support rewards authorize an extension of the exact active generation. The server
      // deliberately requires the current possession nonce, so a fresh random nonce is invalid.
      if (await HivemindService.probeCurrentSession() !=
          SessionProbeResult.active) {
        return false;
      }
      final currentNonce = await HivemindService.getSessionNonce();
      if (currentNonce == null) return false;
      nonce = currentNonce;
    }

    // Debug bypass: emit the same custom_data contract as production, but never persist a main
    // candidate until the server confirms that exact nonce as the active generation.
    if (!adsEnabled && kDebugMode) {
      final deviceId = await CryptoService.getDeviceId();
      try {
        final customData = jsonEncode({
          'device_id': deviceId,
          'ad_type': adType,
          'nonce': nonce,
        });
        final fakeUrl =
            Uri.parse('${AppConfig.hivemindApiPublic}/admob/callback'
                '?signature=test&key_id=test'
                '&custom_data=${Uri.encodeComponent(customData)}');
        final response = await HivemindService.directGet(
          fakeUrl,
          timeout: const Duration(seconds: 8),
        );
        if (response.statusCode != 200) return false;
        if (adType == 'main') {
          return HivemindService.confirmAndSetSessionNonce(nonce);
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
            '[AdManager] Reward earned: ${reward.amount} ${reward.type}');
        if (!rewardCompleter.isCompleted) {
          rewardCompleter.complete(true);
        }
      },
    );

    final earned = await rewardCompleter.future;
    if (!earned) return false;

    // Local onUserEarnedReward is not proof that Google SSV was accepted. For main rewards,
    // commit the possession nonce only after the server projects that exact nonce as active.
    if (adType == 'main') {
      return HivemindService.confirmAndSetSessionNonce(nonce);
    }
    return true;
  }

  @override
  void dispose() {
    _rewardedAd?.dispose();
    super.dispose();
  }
}
