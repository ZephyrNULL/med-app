/// A physical Care Cube box linked to a patient.
class CareBox {
  final String id;
  final String patientId;
  final String deviceId; // matches ESP32 MQTT DEVICE_ID
  final DateTime pairedAt;

  CareBox({
    required this.id,
    required this.patientId,
    required this.deviceId,
    required this.pairedAt,
  });

  factory CareBox.fromMap(Map<String, dynamic> map) {
    return CareBox(
      id: map['id'] as String,
      patientId: (map['patient_id'] ?? '') as String,
      deviceId: (map['device_id'] ?? '') as String,
      pairedAt: map['paired_at'] != null
          ? DateTime.parse(map['paired_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'patient_id': patientId,
      'device_id': deviceId,
      'paired_at': pairedAt.toUtc().toIso8601String(),
    };
  }
}
