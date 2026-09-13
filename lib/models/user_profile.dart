class UserProfile {
  final String id;
  final String role; // 'patient' | 'caregiver'
  final String fullName;
  final String email;
  final String? phone;
  final DateTime? dateOfBirth;
  final String? gender;
  final String? allergies;
  final String? bloodGroup;
  final String? emergencyContactName;
  final String? emergencyContactPhone;

  UserProfile({
    required this.id,
    required this.role,
    required this.fullName,
    required this.email,
    this.phone,
    this.dateOfBirth,
    this.gender,
    this.allergies,
    this.bloodGroup,
    this.emergencyContactName,
    this.emergencyContactPhone,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      id: map['id'] as String,
      role: map['role'] as String,
      fullName: (map['full_name'] ?? '') as String,
      email: (map['email'] ?? '') as String,
      phone: map['phone'] as String?,
      dateOfBirth: map['date_of_birth'] != null
          ? DateTime.tryParse(map['date_of_birth'] as String)
          : null,
      gender: map['gender'] as String?,
      allergies: map['allergies'] as String?,
      bloodGroup: map['blood_group'] as String?,
      emergencyContactName: map['emergency_contact_name'] as String?,
      emergencyContactPhone: map['emergency_contact_phone'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'full_name': fullName,
      'email': email,
      'phone': phone,
      'date_of_birth': dateOfBirth?.toIso8601String(),
      'gender': gender,
      'allergies': allergies,
      'blood_group': bloodGroup,
      'emergency_contact_name': emergencyContactName,
      'emergency_contact_phone': emergencyContactPhone,
    };
  }
}
