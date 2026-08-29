import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class VpnNotificationManager {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static String? _lastTimeLeft;
  static String? _lastSpeedKbps;

  // Android channels are immutable — bump this if settings change.
  static const _channelId = 'revolt_vpn_v4';
  static const _channelName = 'Revolt VPN';
  static const _notifId = 888;

  static Future<void> init() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@drawable/notification_icon');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);

    if (Platform.isAndroid) {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  static Future<void> showOrUpdateStatus({
    required String timeLeft,
    required String speedKbps,
  }) async {
    if (timeLeft == _lastTimeLeft && speedKbps == _lastSpeedKbps) return;
    _lastTimeLeft = timeLeft;
    _lastSpeedKbps = speedKbps;

    if (!_initialized) await init();

    final bodyText = 'Time: $timeLeft  •  $speedKbps';

    final bigPictureStyle = BigPictureStyleInformation(
      const DrawableResourceAndroidBitmap('notification_banner'),
      largeIcon: const DrawableResourceAndroidBitmap('notification_icon'),
      contentTitle: 'Revolt VPN',
      summaryText: bodyText,
      htmlFormatContentTitle: false,
      htmlFormatSummaryText: false,
    );

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Session timer and speed',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      showWhen: false,
      // Session time/speed is usage metadata. Keep it out of public lock-screen
      // previews while leaving the ongoing VPN status notification intact.
      visibility: NotificationVisibility.private,
      usesChronometer: false,
      category: AndroidNotificationCategory.service,
      colorized: true,
      color: const ui.Color(0xFF0D1117),
      styleInformation: bigPictureStyle,
    );

    final details = NotificationDetails(android: androidDetails);

    try {
      await _plugin.show(_notifId, _channelName, bodyText, details);
    } catch (e) {
      _initialized = false;
      try {
        await init();
        await _plugin.show(_notifId, _channelName, bodyText, details);
      } catch (_) {}
    }
  }

  static Future<void> cancel() async {
    if (!_initialized) return;
    await _plugin.cancel(_notifId);
  }
}
