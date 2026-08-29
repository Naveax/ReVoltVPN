import 'package:flutter/services.dart';

class InstalledApp {
  final String packageName;
  final String label;
  final Uint8List? iconPng;

  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.iconPng,
  });
}

abstract final class InstalledAppsService {
  InstalledAppsService._();

  static const MethodChannel _channel = MethodChannel('com.revoltvpn.app/apps');

  static Future<List<InstalledApp>> loadLaunchableApps() async {
    final raw = await _channel.invokeListMethod<dynamic>('getLaunchableApps') ??
        const <dynamic>[];
    final apps = <InstalledApp>[];

    for (final item in raw) {
      if (item is! Map) continue;

      final packageName = item['packageName'];
      final label = item['label'];
      final icon = item['icon'];

      if (packageName is! String || packageName.isEmpty) continue;

      apps.add(
        InstalledApp(
          packageName: packageName,
          label: label is String && label.isNotEmpty ? label : packageName,
          iconPng: icon is Uint8List ? icon : null,
        ),
      );
    }

    apps.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return apps;
  }
}
