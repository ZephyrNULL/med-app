/// A temperature/humidity reading published on `carecube/{device_id}/status`.
class BoxReading {
  final String? id;
  final String? boxId;
  final double temperature;
  final double humidity;
  final DateTime recordedAt;

  BoxReading({
    this.id,
    this.boxId,
    required this.temperature,
    required this.humidity,
    required this.recordedAt,
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
