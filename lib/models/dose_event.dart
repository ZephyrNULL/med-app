/// A dose event published by the ESP32 on `carecube/{device_id}/event`.
///
/// types: reminder_started | taken | missed | emergency_taken |
///        emergency_returned | caregiver_stopped | wrong_bay_taken
class DoseEvent {
  final String? id;
  final String? boxId;
  final String type;
  final int sensorNumber; // 1-7
  final DateTime occurredAt;

  DoseEvent({
    this.id,
    this.boxId,
    required this.type,
    required this.sensorNumber,
    required this.occurredAt,
  });

  factory DoseEvent.fromEventJson(Map<String, dynamic> json) {
    return DoseEvent(
      boxId: json['device_id'] as String?,
      type: (json['type'] ?? '') as String,
      sensorNumber: (json['sensor_number'] ?? 0) as int,
      occurredAt: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              ((json['timestamp'] as num) * 1000).toInt(),
            )
          : DateTime.now(),
    );
  }

  factory DoseEvent.fromMap(Map<String, dynamic> map) {
    return DoseEvent(
      id: map['id'] as String?,
      boxId: map['box_id'] as String?,
      type: (map['event_type'] ?? '') as String,
      sensorNumber: (map['sensor_number'] ?? 0) as int,
      occurredAt: map['occurred_at'] != null
          ? DateTime.parse(map['occurred_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toDbMap(String boxId) {
    return {
      'box_id': boxId,
      'event_type': type,
      'sensor_number': sensorNumber,
      'occurred_at': occurredAt.toUtc().toIso8601String(),
    };
  }

  String get friendlyType {
    switch (type) {
      case 'reminder_started':
        return 'Reminder started';
      case 'taken':
        return 'Dose taken';
      case 'missed':
        return 'Dose missed';
      case 'emergency_taken':
        return 'Emergency Taken';
      case 'emergency_returned':
        return 'Emergency container returned';
      case 'caregiver_stopped':
        return 'Alarm stopped by caregiver';
      case 'wrong_bay_taken':
        return 'Medicine removed from wrong bay';
      default:
        return type;
    }
  }

  bool get isActiveAlarm =>
      type == 'reminder_started' || type == 'emergency_taken';

  /// True for events that only annotate the feed (a medicine removed from a
  /// bay that had no dose due). Such events are neither an alarm nor a
  /// resolution of one: they must never ring or silence the phone, and they
  /// must not mask an outstanding alarm sitting below them in the feed.
  bool get isInformational => type == 'wrong_bay_taken';
}
