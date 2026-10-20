/// A temperature/humidity reading published on `carecube/{device_id}/status`.
///
/// The live alarm fields ([reminderSensor], [wrongBaySensor],
/// [emergencyActive], [doseTriggeredMask]) are published by the firmware so
/// the phone can reconcile its alarm state with the box on every status
/// beat. They are `null` when the connected firmware is older and does not
/// publish them — callers must skip alarm reconciliation in that case.
class BoxReading {
  final String? id;
  final String? boxId;
  final double temperature;
  final double humidity;
  final DateTime recordedAt;

  /// 1-based bay currently ringing a reminder, or 0/absent when none.
  final int? reminderSensor;

  /// 1-based bay currently in the wrong-bay alert, or 0/absent when none.
  final int? wrongBaySensor;

  /// 1 when the box is in the emergency-taken alarm state, 0 otherwise.
  final int? emergencyActive;

  /// Bitmask of bays (bit 0 = bay 1) whose dose has been triggered today.
  final int? doseTriggeredMask;

  BoxReading({
    this.id,
    this.boxId,
    required this.temperature,
    required this.humidity,
    required this.recordedAt,
    this.reminderSensor,
    this.wrongBaySensor,
    this.emergencyActive,
    this.doseTriggeredMask,
  });

  factory BoxReading.fromStatusJson(Map<String, dynamic> json) {
    return BoxReading(
      boxId: json['device_id'] as String?,
      temperature: ((json['temperature'] ?? 0) as num).toDouble(),
      humidity: ((json['humidity'] ?? 0) as num).toDouble(),
      recordedAt: json['timestamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              ((json['timestamp'] as num) * 1000).toInt(),
            )
          : DateTime.now(),
      reminderSensor: (json['reminder_sensor'] as num?)?.toInt(),
      wrongBaySensor: (json['wrong_bay_sensor'] as num?)?.toInt(),
      emergencyActive: (json['emergency'] as num?)?.toInt(),
      doseTriggeredMask: (json['dose_triggered'] as num?)?.toInt(),
    );
  }

  factory BoxReading.fromMap(Map<String, dynamic> map) {
    return BoxReading(
      id: map['id'] as String?,
      boxId: map['box_id'] as String?,
      temperature: ((map['temperature'] ?? 0) as num).toDouble(),
      humidity: ((map['humidity'] ?? 0) as num).toDouble(),
      recordedAt: map['recorded_at'] != null
          ? DateTime.parse(map['recorded_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toDbMap(String boxId) {
    return {
      'box_id': boxId,
      'temperature': temperature,
      'humidity': humidity,
      'recorded_at': recordedAt.toUtc().toIso8601String(),
    };
  }
}
