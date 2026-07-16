import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// ConsentManager wraps Google's UMP (User Messaging Platform) SDK.
///
/// What it does:
/// - Checks whether the user is in the EEA, UK, or another region requiring
///   GDPR-style consent.
/// - If consent is required and hasn't been collected yet, shows Google's
///   standard consent form (handles all the legal wording automatically).
/// - Communicates the user's choices to AdMob so ads respect their preferences.
///
/// This satisfies both Google Play's ad policy requirement AND the EU GDPR
/// requirement for informed consent before personalized ads.
///
/// Usage — call once at app startup before anything else:
/// ```dart
/// await ConsentManager.requestConsentIfNeeded();
/// ```
class ConsentManager {
  ConsentManager._();

  /// Whether the consent flow has completed (consent gathered or not needed).
  static bool _isComplete = false;
  static bool get isComplete => _isComplete;

  /// Run the full consent flow.
  ///
  /// Returns `true` when consent is resolved (or wasn't needed), so the app
  /// can safely proceed to initialize ads and the VPN.
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

      // Request consent info update from Google's servers.
      // In google_mobile_ads 4.0.0 this uses a callback pattern.
      await _requestConsentInfo(params);

      // Check if a consent form is available and needed.
      if (await ConsentInformation.instance.isConsentFormAvailable()) {
        await _loadAndShowForm();
        debugPrint('[Consent] Form shown and dismissed by user.');
      } else {
        debugPrint('[Consent] No consent form needed for this user.');
      }
    } catch (e) {
      // If anything goes wrong, fail open — the app still works, ads just
      // default to non-personalized.
      debugPrint('[Consent] Unexpected error in consent flow: $e');
    }

    _isComplete = true;
    return true;
  }

  /// Wraps the callback-based requestConsentInfoUpdate in a Future.
  static Future<void> _requestConsentInfo(ConsentRequestParameters params) {
    final completer = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () {
        debugPrint('[Consent] Consent info updated successfully.');
        completer.complete();
      },
      (FormError error) {
        debugPrint('[Consent] Failed to update consent info: ${error.message}');
        completer.complete(); // Proceed anyway
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => debugPrint('[Consent] Consent info request timed out.'),
    );
  }

  /// Loads and shows the consent form with a timeout.
  static Future<void> _loadAndShowForm() {
    final completer = Completer<void>();

    ConsentForm.loadConsentForm(
      (ConsentForm form) {
        debugPrint('[Consent] Form loaded — showing.');
        form.show((FormError? dismissError) {
          if (dismissError != null) {
            debugPrint('[Consent] Form dismissed with error: ${dismissError.message}');
          }
          completer.complete();
        });
      },
      (FormError loadError) {
        debugPrint('[Consent] Form load error: ${loadError.message}');
        completer.complete(); // Proceed anyway
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () => debugPrint('[Consent] Form show timed out.'),
    );
  }

  /// Resets consent state. Useful for testing; NOT for production.
  static Future<void> resetForTesting() async {
    await ConsentInformation.instance.reset();
    _isComplete = false;
  }
}
