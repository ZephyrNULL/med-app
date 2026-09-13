/// A patient <-> caregiver link.
class CaregiverLink {
  final String id;
  final String patientId;
  final String caregiverId;
  final String status; // 'pending' | 'active'

  CaregiverLink({
    required this.id,
    required this.patientId,
    required this.caregiverId,
    required this.status,
  });

  factory CaregiverLink.fromMap(Map<String, dynamic> map) {
    return CaregiverLink(
      id: map['id'] as String,
      patientId: (map['patient_id'] ?? '') as String,
      caregiverId: (map['caregiver_id'] ?? '') as String,
      status: (map['status'] ?? 'pending') as String,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'patient_id': patientId,
      'caregiver_id': caregiverId,
      'status': status,
    };
  }
}
