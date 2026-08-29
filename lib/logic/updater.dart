import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:revoltvpn/logic/app_config.dart';
import 'package:revoltvpn/logic/app_colors.dart';

enum UpdateStatus { upToDate, updateAvailable, checkFailed }

enum InstallSource { playStore, sideload }

Uri? _trustedHttpsUri(String raw, Set<String> allowedHosts) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'https' || !allowedHosts.contains(uri.host)) {
    return null;
  }
  return uri;
}

class PlayStoreUpdater {
  PlayStoreUpdater._();

  static String get _url =>
      'https://play.google.com/store/apps/details?id=${AppConfig.applicationId}';

  static Future<bool> open() async {
    final uri = _trustedHttpsUri(_url, const {'play.google.com'});
    if (uri == null) {
      debugPrint('[Updater] Refusing invalid Play Store URL.');
      return false;
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Updater] Failed to open Play Store: $e');
      return false;
    }
  }
}

class GitHubUpdater {
  GitHubUpdater._();

  static String? _cachedDownloadUrl;

  static Future<String?> fetchLatestVersion() async {
    final apiUri = Uri.https(
      'api.github.com',
      '/repos/${AppConfig.githubOwner}/${AppConfig.githubRepo}/releases/latest',
    );

    try {
      final response = await http
          .get(apiUri, headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        debugPrint('[Updater] GitHub API returned ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('[Updater] Invalid GitHub release payload.');
        return null;
      }

      final htmlUrl = decoded['html_url'];
      if (htmlUrl is String &&
          _trustedHttpsUri(htmlUrl, const {'github.com'}) != null) {
        _cachedDownloadUrl = htmlUrl;
      } else {
        _cachedDownloadUrl = null;
      }

      final rawTag = decoded['tag_name'];
      if (rawTag is! String || rawTag.isEmpty || rawTag.length > 64) {
        debugPrint('[Updater] Invalid release tag.');
        return null;
      }

      return rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
    } catch (e) {
      debugPrint('[Updater] GitHub API error: $e');
      return null;
    }
  }

  static Future<bool> open() async {
    final raw = _cachedDownloadUrl ?? AppConfig.githubReleasesUrl;
    final uri = _trustedHttpsUri(raw, const {'github.com'});
    if (uri == null) {
      debugPrint('[Updater] Refusing untrusted GitHub update URL.');
      return false;
    }

    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Updater] Failed to open GitHub: $e');
      return false;
    }
  }
}

class Updater {
  Updater._();

  static InstallSource? _cachedSource;

  static Future<InstallSource> get installSource async {
    if (_cachedSource != null) return _cachedSource!;
    if (kIsWeb || !Platform.isAndroid) {
      _cachedSource = InstallSource.sideload;
      return _cachedSource!;
    }

    try {
      final result = await MethodChannel('com.revoltvpn.app/installer')
          .invokeMethod<String>('getInstallerPackage');
      _cachedSource = (result == 'com.android.vending')
          ? InstallSource.playStore
          : InstallSource.sideload;
    } catch (e) {
      debugPrint('[Updater] Installer check failed: $e');
      _cachedSource = InstallSource.sideload;
    }

    return _cachedSource!;
  }

  static int _compareVersions(String a, String b) {
    final aParts = a.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final bParts = b.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    for (int i = 0; i < 3; i++) {
      final diff = (aParts.length > i ? aParts[i] : 0) -
          (bParts.length > i ? bParts[i] : 0);
      if (diff != 0) return diff;
    }
    return 0;
  }

  static String _versionLabel(String v, bool isLocal) {
    final prefix = v.startsWith('v') ? '' : 'v';
    return '$prefix$v${isLocal ? ' (installed)' : ''}';
  }

  static Future<void> check(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    return checkWithHandles(
      navigator: navigator,
      messenger: messenger,
    );
  }

  static Future<void> checkWithHandles({
    required NavigatorState navigator,
    required ScaffoldMessengerState messenger,
  }) async {
    final info = await PackageInfo.fromPlatform();
    final localVersion = info.version;
    if (localVersion.isEmpty) {
      _showSnackBar(messenger, 'Could not determine app version',
          isError: true);
      return;
    }

    final latestVersion = await GitHubUpdater.fetchLatestVersion();
    if (latestVersion == null) {
      _showSnackBar(messenger, 'Could not reach GitHub', isError: true);
      return;
    }

    if (_compareVersions(localVersion, latestVersion) >= 0) {
      _showSnackBar(messenger, 'Up to date');
      return;
    }

    final source = await installSource;
    final storeName =
        source == InstallSource.playStore ? 'Play Store' : 'GitHub';
    if (!navigator.mounted) return;

    showDialog(
      context: navigator.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgCard,
        title: const Text('Update available',
            style: TextStyle(color: AppColors.textWhite)),
        content: Text(
          '${_versionLabel(latestVersion, false)} is available on $storeName.\n'
          'You have ${_versionLabel(localVersion, true)}.',
          style: const TextStyle(color: AppColors.slate70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later',
                style: TextStyle(color: AppColors.slate70)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              source == InstallSource.playStore
                  ? PlayStoreUpdater.open()
                  : GitHubUpdater.open();
            },
            child: Text('Open $storeName',
                style: const TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  static void _showSnackBar(
    ScaffoldMessengerState messenger,
    String message, {
    bool isError = false,
  }) {
    if (!messenger.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(isError ? Icons.error_outline : Icons.check_circle,
                color: isError ? AppColors.red : AppColors.green,
                size: 18),
            const SizedBox(width: 8),
            Text(message),
          ],
        ),
        backgroundColor: AppColors.bgCard,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
