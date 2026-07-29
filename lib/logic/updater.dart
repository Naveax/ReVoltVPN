import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/app_colors.dart';

/// Result of a manual version check.
enum UpdateStatus {
  upToDate,
  updateAvailable,
  checkFailed,
}

/// How the user installed this app — determines which store link we open.
enum InstallSource {
  playStore,
  sideload,
}


// ##############################################################################
//                                                                            #
//                              APPROACH #1                                    #
//                         GOOGLE PLAY STORE LINK                              #
//                                                                            #
//   Opens the Play Store listing.  User taps "Update" in Play Store like     #
//   any normal app.  No background downloads, no in-app update package,      #
//   no permissions.  Just a URL.                                             #
//                                                                            #
//   The Play Store page is built from the applicationId:                      #
//     https://play.google.com/store/apps/details?id=com.paladinvpn.app        #
//                                                                            #
// ##############################################################################

class PlayStoreUpdater {
  PlayStoreUpdater._();

  static String get _url =>
      'https://play.google.com/store/apps/details?id=${AppConfig.applicationId}';

  /// Opens the Play Store listing in the Play Store app (or browser fallback).
  static Future<bool> open() async {
    try {
      return await launchUrl(Uri.parse(_url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Updater] Failed to open Play Store: $e');
      return false;
    }
  }
}


// ##############################################################################
//                                                                            #
//                              APPROACH #2                                    #
//                         GITHUB RELEASES DIRECT                              #
//                                                                            #
//   Opens the GitHub releases page.  User downloads the APK and Android's     #
//   package installer handles the rest.  No permissions, no self-hosting.     #
//                                                                            #
//   The GitHub Releases API (free, public, no auth) is also used as the       #
//   single source of truth for "what is the latest version?" for both paths.  #
//                                                                            #
//   API:  GET https://api.github.com/repos/{owner}/{repo}/releases/latest      #
//                                                                            #
// ##############################################################################

class GitHubUpdater {
  GitHubUpdater._();

  static String? _cachedDownloadUrl;

  /// Fetches the latest release tag from GitHub.
  /// Returns the version string (e.g. "1.0.7") or null on failure.
  ///
  /// Tags should follow semver with an optional "v" prefix:
  ///   git tag v1.0.7 && git push origin v1.0.7
  static Future<String?> fetchLatestVersion() async {
    final url = 'https://api.github.com/repos/${AppConfig.githubOwner}/${AppConfig.githubRepo}/releases/latest';

    try {
      final response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        debugPrint('[Updater] GitHub API returned ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _cachedDownloadUrl = data['html_url'] as String?;

      final tag = data['tag_name'] as String? ?? '0.0.0';
      return tag.startsWith('v') ? tag.substring(1) : tag;
    } catch (e) {
      debugPrint('[Updater] GitHub API error: $e');
      return null;
    }
  }

  /// Opens the GitHub releases page for the latest release.
  static Future<bool> open() async {
    final url = _cachedDownloadUrl ?? AppConfig.githubReleasesUrl;
    try {
      return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Updater] Failed to open GitHub: $e');
      return false;
    }
  }
}


// ##############################################################################
//                                                                            #
//                              SHARED LOGIC                                   #
//                         VERSION CHECK & GLUE                                #
//                                                                            #
//   Updater.check(context) — call from the sidebar button.  It:               #
//                                                                            #
//     1. Fetches the latest version from GitHub Releases API                  #
//     2. Compares to the local version from the app bundle                    #
//     3. Up to date? → green snackbar                                         #
//     4. Update available? → dialog, then redirects to Play Store or GitHub   #
//                                                                            #
// ##############################################################################

class Updater {
  Updater._();

  static InstallSource? _cachedSource;

  /// Detects where this app was installed from.
  ///
  ///   • com.android.vending → Play Store
  ///   • anything else / null → sideloaded (GitHub APK, etc.)
  static Future<InstallSource> get installSource async {
    if (_cachedSource != null) return _cachedSource!;

    if (kIsWeb || !Platform.isAndroid) {
      _cachedSource = InstallSource.sideload;
      return _cachedSource!;
    }

    // In debug mode the app isn't signed with a Play Console certificate,
    // so we default to the sideload path.
    if (kDebugMode) {
      debugPrint('[Updater] Debug mode — treating install source as sideload.');
      _cachedSource = InstallSource.sideload;
      return _cachedSource!;
    }

    try {
      final source = await _detectInstallerSource();
      _cachedSource = source;
      debugPrint('[Updater] Install source: ${source.name}');
      return source;
    } catch (e) {
      debugPrint('[Updater] Installer detection failed, assuming sideload: $e');
      _cachedSource = InstallSource.sideload;
      return _cachedSource!;
    }
  }

  static Future<InstallSource> _detectInstallerSource() async {
    // Install source detection is stubbed until the native method channel
    // is wired in MainActivity.kt.  Without it, all users default to the
    // GitHub update path — which works, but Play Store users should ideally
    // be sent to the Play Store listing instead.
    //
    // To wire: add a MethodChannel named "com.revoltvpn.app/installer" in
    // MainActivity.kt that calls PackageManager.getInstallerPackageName().
    // If it returns "com.android.vending", return InstallSource.playStore.
    // Then uncomment the 7 lines below and delete the fallback return.
    //
    // const channel = MethodChannel('com.revoltvpn.app/installer');
    // final installer = await channel.invokeMethod<String>('getInstallerPackage');
    // if (installer == 'com.android.vending') {
    //   return InstallSource.playStore;
    // }
    // return InstallSource.sideload;
    return InstallSource.sideload; // Stubbed — see above.
  }

  /// Compares two semver strings.  Positive = a > b, negative = a < b, 0 = equal.
  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final bParts = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return av - bv;
    }
    return 0;
  }

  /// Call this from the sidebar "Check for updates" button.
  ///
  /// Returns the [UpdateStatus] for programmatic use, but the UI
  /// (snackbar or dialog) is already handled.
  static Future<UpdateStatus> check(BuildContext context) async {
    // 1. Local version from the app bundle.
    final localVersion = (await PackageInfo.fromPlatform()).version;
    debugPrint('[Updater] Local version: $localVersion');

    // 2. Latest version from GitHub (single source of truth for both paths).
    final latestVersion = await GitHubUpdater.fetchLatestVersion();
    if (latestVersion == null) {
      debugPrint('[Updater] Could not determine latest version.');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not check for updates.  Try again later.'),
            backgroundColor: AppColors.bgCard,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return UpdateStatus.checkFailed;
    }

    debugPrint('[Updater] Latest version: $latestVersion');

    // 3. Compare.
    if (_compareVersions(localVersion, latestVersion) >= 0) {
      debugPrint('[Updater] App is up to date.');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓  Up to date (v$localVersion)'),
            backgroundColor: AppColors.bgCard,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return UpdateStatus.upToDate;
    }

    // 4. Update available — open the store immediately, no dialog.
    debugPrint('[Updater] Update available: $localVersion → $latestVersion');

    final source = await installSource;
    final isPlayStore = source == InstallSource.playStore;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Opening ${isPlayStore ? 'Play Store' : 'GitHub'}…'),
          backgroundColor: AppColors.bgCard,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    if (isPlayStore) {
      await PlayStoreUpdater.open();
    } else {
      await GitHubUpdater.open();
    }
    return UpdateStatus.updateAvailable;
  }
}


// ##############################################################################
//                                                                            #
//                         INTEGRATION GUIDE                                   #
//                                                                            #
//  1. pubspec.yaml — add:                                                     #
//                                                                             #
//       package_info_plus: ^6.0.0                                             #
//                                                                             #
//  2. app_config.dart — add these constants:                                  #
//                                                                             #
//       static const String applicationId = 'com.paladinvpn.app';              #
//       static const String githubOwner   = 'revoltvpn';                       #
//       static const String githubRepo    = 'revoltvpn';                       #
//                                                                             #
//  3. Android native — add to MainActivity.kt for install source detection:   #
//                                                                             #
//       override fun configureFlutterEngine(flutterEngine: FlutterEngine) {   #
//         super.configureFlutterEngine(flutterEngine)                         #
//         MethodChannel(                                                      #
//           flutterEngine.dartExecutor.binaryMessenger,                       #
//           "com.revoltvpn.app/installer"                                     #
//         ).setMethodCallHandler { call, result ->                            #
//           if (call.method == "getInstallerPackage") {                       #
//             val installer = packageManager                                  #
//               .getInstallerPackageName(packageName)                         #
//             result.success(installer)                                       #
//           } else {                                                          #
//             result.notImplemented()                                         #
//           }                                                                 #
//         }                                                                   #
//       }                                                                     #
//                                                                             #
//  4. Already wired — sidebar button calls Updater.check(context).             #
//                                                                             #
//  5. Tag releases with semver on GitHub:                                     #
//                                                                             #
//       git tag v1.0.7                                                        #
//       git push origin v1.0.7                                                #
//                                                                             #
// ##############################################################################
