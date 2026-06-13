import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class VpnNotificationManager {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);

    // Request POST_NOTIFICATIONS permission on Android 13+
    if (Platform.isAndroid) {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  static String? _lastTimeLeft;
  static String? _lastSpeedKbps;

  static Future<void> showOrUpdateStatus({
    required String timeLeft,
    required String speedKbps,
  }) async {
    // Skip update if nothing changed — prevents notification flicker
    // on Android skins that animate every notification update.
    if (timeLeft == _lastTimeLeft && speedKbps == _lastSpeedKbps) return;
    _lastTimeLeft  = timeLeft;
    _lastSpeedKbps = speedKbps;

    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      'paladin_vpn_status',
      'VPN Status',
      channelDescription: 'Persistent notification shown while VPN is active',
      importance: Importance.low,
      priority: Priority.low,
      // Non-dismissable while VPN is running
      ongoing: true,
      autoCancel: false,
      // Silent updates — no sound or vibration each time stats refresh
      playSound: false,
      enableVibration: false,
      onlyAlertOnce: true,
      // Hide the auto-generated timestamp
      showWhen: false,
      // Show on lock screen
      visibility: NotificationVisibility.public,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    await _plugin.show(
      888, // Fixed ID — always updates the same notification
      'Paladin VPN Active',
      'Time: $timeLeft  •  $speedKbps',
      notificationDetails,
    );
  }

  static Future<void> cancel() async {
    if (!_initialized) return;
    await _plugin.cancel(888);
  }
}

