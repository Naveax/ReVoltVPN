import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class VpnNotificationManager {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@drawable/notification_icon');
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

    // NOTE: The channel ID includes 'v2' to force Android to create a fresh
    // notification channel. Android channels are immutable once created — if
    // the old channel was created without 'ongoing: true', users would be
    // stuck with a swipeable notification forever.
    const androidDetails = AndroidNotificationDetails(
      'revolt_vpn_status_v2',
      'VPN Status',
      channelDescription: 'Shown while VPN is active — non-dismissable',
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
      // Extra insurance against swipe-to-dismiss on aggressive Android skins
      usesChronometer: false,
      category: AndroidNotificationCategory.service,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    try {
      await _plugin.show(
        888, // Fixed ID — always updates the same notification
        'REVOLT VPN Active',
        'Time: $timeLeft  •  $speedKbps',
        notificationDetails,
      );
    } catch (e) {
      // If showing fails (e.g. permission revoked), try to recover by
      // re-initializing and retrying once.
      _initialized = false;
      try {
        await init();
        await _plugin.show(
          888,
          'REVOLT VPN Active',
          'Time: $timeLeft  •  $speedKbps',
          notificationDetails,
        );
      } catch (_) {
        // Give up — the VPN still works, just without the notification.
      }
    }
  }

  static Future<void> cancel() async {
    if (!_initialized) return;
    await _plugin.cancel(888);
  }
}

