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
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
  }

  /// Show a notification when a reminder/emergency event lands even if the
  /// app is backgrounded. In production this would be driven by FCM; local
  /// notifications here act as the in-app fallback.
  ///
  /// [id] must be stable per alarm kind (reminder = 1, wrong-bay = 2,
  /// emergency = 3) so a repeat replaces the previous notification instead
  /// of stacking a new one every time.
  Future<void> showAlarmNotification({
    required String title,
    required String body,
    int id = 1,
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

    await _plugin.show(id, title, body, details);
  }
}
