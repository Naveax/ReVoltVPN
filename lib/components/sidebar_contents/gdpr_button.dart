import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:revoltvpn/logic/app_colors.dart';
import 'package:url_launcher/url_launcher.dart';

class GdprButton extends StatelessWidget {
  const GdprButton({super.key});

  static Future<void> showConsentForm() async {
    try {
      // If the form is already available, show it directly — no need to
      // re-request consent info from Google's servers on every tap.
      if (await ConsentInformation.instance.isConsentFormAvailable()) {
        await _loadAndShowForm();
        return;
      }

      // Form not available — refresh consent info first, then try again.
      final completer = Completer<void>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () async {
          if (await ConsentInformation.instance.isConsentFormAvailable()) {
            await _loadAndShowForm();
          }
          completer.complete();
        },
        (FormError error) {
          debugPrint('[GDPR] Consent update error: ${error.message}');
          _fallbackToPrivacyPolicy();
          completer.complete();
        },
      );
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: _fallbackToPrivacyPolicy,
      );
    } catch (e) {
      debugPrint('[GDPR] Error: $e');
      _fallbackToPrivacyPolicy();
    }
  }

  static Future<void> _loadAndShowForm() async {
    final completer = Completer<void>();
    ConsentForm.loadConsentForm(
      (ConsentForm form) {
        form.show((FormError? dismissError) {
          if (dismissError != null) {
            debugPrint('[GDPR] Form dismissed with error: ${dismissError.message}');
          }
          completer.complete();
        });
      },
      (FormError loadError) {
        debugPrint('[GDPR] Form load error: ${loadError.message}');
        _fallbackToPrivacyPolicy();
        completer.complete();
      },
    );
    await completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: _fallbackToPrivacyPolicy,
    );
  }

  static void _fallbackToPrivacyPolicy() async {
    final Uri url = Uri.parse(
      'https://github.com/esefxdz/ReVoltVPN/blob/main/PRIVACY_POLICY.md',
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const IconButton(
      icon: Icon(
        Icons.admin_panel_settings_outlined,
        color: AppColors.textWhite,
        size: 28,
      ),
      onPressed: showConsentForm,
      tooltip: 'Ad consent & privacy choices',
      splashRadius: 24,
    );
  }
}
