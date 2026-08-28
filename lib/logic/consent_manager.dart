import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Handles Google UMP consent before the Mobile Ads SDK is initialized.
///
/// This implementation intentionally fails closed: if consent information
/// cannot be refreshed, the form cannot be completed, or the final consent
/// status is unresolved, callers must not request ads.
class ConsentManager {
  ConsentManager._();

  static bool _isComplete = false;
  static bool _canRequestAds = false;

  static bool get isComplete => _isComplete;
  static bool get canRequestAds => _isComplete && _canRequestAds;

  /// Resolves the UMP consent state.
  ///
  /// google_mobile_ads 4.0.0 does not expose UMP's newer canRequestAds API, so
  /// the compatible safe gate is the final [ConsentStatus]. Ads are allowed
  /// only when consent is obtained or consent is not required.
  static Future<bool> requestConsentIfNeeded() async {
    if (_isComplete) return _canRequestAds;

    _canRequestAds = false;

    try {
      final params = ConsentRequestParameters(
        consentDebugSettings: kDebugMode
            ? ConsentDebugSettings(
                debugGeography: DebugGeography.debugGeographyEea,
                testIdentifiers: [],
              )
            : null,
      );

      await _requestConsentInfo(params)
          .timeout(const Duration(seconds: 10));

      if (await ConsentInformation.instance.isConsentFormAvailable()) {
        await _loadAndShowForm().timeout(const Duration(minutes: 2));
      }

      final status = await ConsentInformation.instance
          .getConsentStatus()
          .timeout(const Duration(seconds: 5));

      _canRequestAds = status == ConsentStatus.obtained ||
          status == ConsentStatus.notRequired;
      _isComplete = true;

      if (!_canRequestAds) {
        debugPrint('[Consent] Ads blocked; unresolved consent status: $status');
      }

      return _canRequestAds;
    } on TimeoutException catch (e) {
      debugPrint('[Consent] Consent flow timed out: $e');
    } catch (e) {
      debugPrint('[Consent] Consent flow failed closed: $e');
    }

    // Do not cache failures as a successful/complete consent state. A later
    // attempt may succeed after connectivity or UMP recovers.
    _isComplete = false;
    _canRequestAds = false;
    return false;
  }

  static Future<void> _requestConsentInfo(
    ConsentRequestParameters params,
  ) {
    final completer = Completer<void>();

    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () {
        if (!completer.isCompleted) completer.complete();
      },
      (FormError error) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Consent info update failed: ${error.message}'),
          );
        }
      },
    );

    return completer.future;
  }

  static Future<void> _loadAndShowForm() {
    final completer = Completer<void>();

    ConsentForm.loadConsentForm(
      (ConsentForm form) {
        form.show((FormError? dismissError) {
          if (completer.isCompleted) return;

          if (dismissError != null) {
            completer.completeError(
              StateError('Consent form failed: ${dismissError.message}'),
            );
            return;
          }

          completer.complete();
        });
      },
      (FormError loadError) {
        if (!completer.isCompleted) {
          completer.completeError(
            StateError('Consent form load failed: ${loadError.message}'),
          );
        }
      },
    );

    return completer.future;
  }

  /// Testing helper. Do not expose this from production UI.
  static Future<void> resetForTesting() async {
    await ConsentInformation.instance.reset();
    _isComplete = false;
    _canRequestAds = false;
  }
}
