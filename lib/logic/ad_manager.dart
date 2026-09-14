import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/consent_manager.dart';
import 'package:revoltvpn/logic/crypto_service.dart';
import 'package:revoltvpn/logic/hivemind_service.dart';
import 'package:revoltvpn/logic/session_activation_service.dart';

class AdManager extends ChangeNotifier {
  static const bool adsEnabled = false;

  RewardedAd? _rewardedAd;

  bool _isAdLoaded = false;
  bool get isAdLoaded => adsEnabled ? _isAdLoaded : true;

  bool _isAdLoading = false;
  bool get isAdLoading => adsEnabled ? _isAdLoading : false;

  Completer<bool>? _loadCompleter;

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
      await ConsentManager.requestConsentIfNeeded().timeout(
        const Duration(seconds: 5),
      );
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

  Future<bool> showAd(String adType) async {
    if (adType != 'main' && adType != 'support') {
      debugPrint('[AdManager] Rejected unknown ad type.');
      return false;
    }

    String nonce;
    SessionActivationIntent? h13Intent;

    if (adType == 'main') {
      if (!await HivemindService.retryPendingSessionStop()) {
        debugPrint('[AdManager] Server session revocation is still pending.');
        return false;
      }

      final existing = await HivemindService.probeCurrentSession();
      if (existing == SessionProbeResult.active) {
        return true;
      }
      if (existing == SessionProbeResult.unavailable) {
        return false;
      }
      nonce = HivemindService.newNonce();
    } else {
      if (await HivemindService.probeCurrentSession() !=
          SessionProbeResult.active) {
        return false;
      }
      final currentNonce = await HivemindService.getSessionNonce();
      if (currentNonce == null) return false;
      nonce = currentNonce;
    }

    // H13 deliberately does not participate in the local signature=test compatibility path.
    // That backend route forbids the bypass entirely, so debug continues using the frozen legacy
    // candidate contract even when the production H13 gate is enabled in a private test config.
    if (!adsEnabled && kDebugMode) {
      if (adType == 'main' &&
          !await HivemindService.reserveSessionCandidate(nonce)) {
        debugPrint('[AdManager] Main session candidate reservation failed.');
        return false;
      }

      final deviceId = await CryptoService.getDeviceId();
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

    if (adType == 'main') {
      if (AppConfig.h13ActivationEnabled) {
        final prepared = await SessionActivationService.prepare();
        if (prepared == null) {
          debugPrint('[AdManager] H13 activation preparation unavailable.');
          return false;
        }
        h13Intent = prepared;
        // Only this public UUID crosses into Google-visible custom_data. The private session
        // secret remains inside SessionActivationService and first-party HTTPS requests.
        nonce = prepared.activationId;
      } else if (!await HivemindService.reserveSessionCandidate(nonce)) {
        debugPrint('[AdManager] Main session candidate reservation failed.');
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

    Future<void> cleanupUnrewardedMain() async {
      if (adType != 'main') return;
      if (h13Intent != null) {
        await SessionActivationService.recoverPendingAbandonment();
      } else {
        await HivemindService.cancelSessionCandidate(nonce);
      }
    }

    try {
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
    } catch (_) {
      await cleanupUnrewardedMain();
      return false;
    }

    final earned = await rewardCompleter.future;
    if (!earned) {
      await cleanupUnrewardedMain();
      return false;
    }

    if (adType == 'main') {
      final prepared = h13Intent;
      if (prepared != null) {
        return SessionActivationService.confirmAndPromote(prepared);
      }
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
