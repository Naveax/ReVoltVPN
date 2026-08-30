import 'package:flutter/services.dart';

// ── lib/logic/notification_service.dart ─────────────────────────────────────
// Bridge to the native VPN notification, which flutter_vless owns. This only
// refreshes its content text with the session countdown, so a failure here is
// never worth propagating to the session timer.

class NotificationService {
  NotificationService._();

  static const MethodChannel _channel =
      MethodChannel('com.revoltvpn.app/notification');

  static String? _lastText;

  /// Sets the notification's content text to [text].
  ///
  /// The native side rebuilds the whole notification, so skip the round-trip
  /// when the text has not changed.
  static Future<void> updateTimer(String text) async {
    if (text == _lastText) return;
    _lastText = text;
    try {
      await _channel.invokeMethod<void>('updateNotificationText', {
        'title': 'Revolt VPN',
        'text': text,
        'disconnectLabel': 'Disconnect',
      });
    } catch (_) {
      // Cosmetic.
    }
  }

  /// Forces the next connect to re-post even if the countdown resumes on the
  /// same value.
  static void reset() => _lastText = null;
}
