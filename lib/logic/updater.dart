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

class PlayStoreUpdater {
  PlayStoreUpdater._();

  static String get _url =>
      'https://play.google.com/store/apps/details?id=${AppConfig.applicationId}';

  static Future<bool> open() async {
    try {
      return await launchUrl(Uri.parse(_url),
          mode: LaunchMode.externalApplication);
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
    final url =
        'https://api.github.com/repos/${AppConfig.githubOwner}/${AppConfig.githubRepo}/releases/latest';

    try {
      final response = await http
          .get(Uri.parse(url),
              headers: {'Accept': 'application/vnd.github+json'})
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

  static Future<bool> open() async {
    final url = _cachedDownloadUrl ?? AppConfig.githubReleasesUrl;
    try {
      return await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
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

  static Future<void> check(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    final localVersion = info.version;
    if (localVersion.isEmpty) {
      _showSnackBar(context, 'Could not determine app version',
          isError: true);
      return;
    }

    final latestVersion = await GitHubUpdater.fetchLatestVersion();
    if (latestVersion == null) {
      _showSnackBar(context, 'Could not reach GitHub', isError: true);
      return;
    }

    if (_compareVersions(localVersion, latestVersion) >= 0) {
      _showSnackBar(context, 'Up to date');
      return;
    }

    final source = await installSource;
    final storeName = source == InstallSource.playStore ? 'Play Store' : 'GitHub';
    if (!context.mounted) return;

    showDialog(
      context: context,
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

  static void _showSnackBar(BuildContext context, String message,
      {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
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
