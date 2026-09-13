import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance =
      NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);
  }

  /// Show a notification when a reminder/emergency event lands even if the
  /// app is backgrounded. In production this would be driven by FCM; local
  /// notifications here act as the in-app fallback.
  Future<void> showAlarmNotification({
    required String title,
    required String body,
  }) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'care_cube_alarms',
        'Care Cube Alarms',
        channelDescription: 'Medicine reminder and emergency alerts',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }
}
