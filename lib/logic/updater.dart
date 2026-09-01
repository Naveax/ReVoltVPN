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

class _ParsedVersion {
  final List<int> core;
  final List<String> preRelease;

  const _ParsedVersion(this.core, this.preRelease);

  static _ParsedVersion? tryParse(String input) {
    var value = input.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    value = value.split('+').first;
    final dash = value.indexOf('-');
    final corePart = dash < 0 ? value : value.substring(0, dash);
    final prePart = dash < 0 ? '' : value.substring(dash + 1);
    final rawCore = corePart.split('.');
    if (rawCore.isEmpty || rawCore.any((p) => int.tryParse(p) == null)) {
      return null;
    }
    // This list must stay growable because short versions such as 3.3 are
    // normalized to 3.3.0 below.
    final core = rawCore.map(int.parse).toList();
    while (core.length < 3) {
      core.add(0);
    }
    final pre = prePart.isEmpty
        ? const <String>[]
        : prePart.split('.').where((e) => e.isNotEmpty).toList(growable: false);
    return _ParsedVersion(core, pre);
  }

  int compareTo(_ParsedVersion other) {
    final length = core.length > other.core.length ? core.length : other.core.length;
    for (var i = 0; i < length; i++) {
      final left = i < core.length ? core[i] : 0;
      final right = i < other.core.length ? other.core[i] : 0;
      if (left != right) return left.compareTo(right);
    }

    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final preLength = preRelease.length > other.preRelease.length
        ? preRelease.length
        : other.preRelease.length;
    for (var i = 0; i < preLength; i++) {
      if (i >= preRelease.length) return -1;
      if (i >= other.preRelease.length) return 1;
      final left = preRelease[i];
      final right = other.preRelease[i];
      final leftNum = int.tryParse(left);
      final rightNum = int.tryParse(right);
      if (leftNum != null && rightNum != null) {
        if (leftNum != rightNum) return leftNum.compareTo(rightNum);
        continue;
      }
      if (leftNum != null) return -1;
      if (rightNum != null) return 1;
      final lexical = left.compareTo(right);
      if (lexical != 0) return lexical;
    }
    return 0;
  }
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

      final normalized = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
      if (_ParsedVersion.tryParse(normalized) == null) {
        debugPrint('[Updater] Release tag is not a supported version: $rawTag');
        return null;
      }
      return normalized;
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
    final left = _ParsedVersion.tryParse(a);
    final right = _ParsedVersion.tryParse(b);
    if (left == null || right == null) {
      // Invalid local metadata should not invent an ordering.
      return 0;
    }
    return left.compareTo(right);
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
    if (localVersion.isEmpty || _ParsedVersion.tryParse(localVersion) == null) {
      _showSnackBar(
        messenger,
        'Could not determine app version',
        isError: true,
      );
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
        title: const Text(
          'Update available',
          style: TextStyle(color: AppColors.textWhite),
        ),
        content: Text(
          '${_versionLabel(latestVersion, false)} is available on $storeName.\n'
          'You have ${_versionLabel(localVersion, true)}.',
          style: const TextStyle(color: AppColors.slate70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Later',
              style: TextStyle(color: AppColors.slate70),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              source == InstallSource.playStore
                  ? PlayStoreUpdater.open()
                  : GitHubUpdater.open();
            },
            child: Text(
              'Open $storeName',
              style: const TextStyle(color: AppColors.accent),
            ),
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
            Icon(
              isError ? Icons.error_outline : Icons.check_circle,
              color: isError ? AppColors.red : AppColors.green,
              size: 18,
            ),
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
