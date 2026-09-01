import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Resolves Google's UMP consent state before AdMob is initialized.
class ConsentManager {
  ConsentManager._();

  static bool _isComplete = false;
  static bool get isComplete => _isComplete;

  /// Returns true only when consent was successfully resolved or not required.
  /// Network/form failures are not consent decisions, so callers must not load
  /// ads until a later retry succeeds.
  static Future<bool> requestConsentIfNeeded() async {
    if (_isComplete) return true;

    try {
      final params = ConsentRequestParameters(
        consentDebugSettings: kDebugMode
            ? ConsentDebugSettings(
                debugGeography: DebugGeography.debugGeographyEea,
                testIdentifiers: [],
              )
            : null,
      );

      await _requestConsentInfo(params);

      if (await ConsentInformation.instance.isConsentFormAvailable()) {
        await _loadAndShowForm();
        debugPrint('[Consent] Consent form resolved.');
      } else {
        debugPrint('[Consent] No consent form required for this user.');
      }

      _isComplete = true;
      return true;
    } catch (e) {
      debugPrint('[Consent] Consent remains unresolved: $e');
      return false;
    }
  }

  static Future<void> _requestConsentInfo(ConsentRequestParameters params) {
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
    return completer.future.timeout(const Duration(seconds: 10));
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

    return completer.future.timeout(const Duration(seconds: 120));
  }

  static Future<void> resetForTesting() async {
    await ConsentInformation.instance.reset();
    _isComplete = false;
  }
}
