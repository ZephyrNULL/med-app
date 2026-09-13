import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user_profile.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../widgets/common.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _fullName;
  late TextEditingController _phone;
  late TextEditingController _gender;
  late TextEditingController _allergies;
  late TextEditingController _bloodGroup;
  late TextEditingController _emergencyName;
  late TextEditingController _emergencyPhone;
  DateTime? _dob;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final p = context.read<AppState>().profile;
    _fullName = TextEditingController(text: p?.fullName ?? '');
    _phone = TextEditingController(text: p?.phone ?? '');
    _gender = TextEditingController(text: p?.gender ?? '');
    _allergies = TextEditingController(text: p?.allergies ?? '');
    _bloodGroup = TextEditingController(text: p?.bloodGroup ?? '');
    _emergencyName = TextEditingController(text: p?.emergencyContactName ?? '');
    _emergencyPhone =
        TextEditingController(text: p?.emergencyContactPhone ?? '');
    _dob = p?.dateOfBirth;
  }

  @override
  void dispose() {
    _fullName.dispose();
    _phone.dispose();
    _gender.dispose();
    _allergies.dispose();
    _bloodGroup.dispose();
    _emergencyName.dispose();
    _emergencyPhone.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(1990),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final user = SupabaseService.currentUser!;
    final p = context.read<AppState>().profile;
    try {
      await SupabaseService.upsertProfile({
        'id': user.id,
        'role': p?.role ?? 'patient',
        'full_name': _fullName.text.trim(),
        'email': p?.email ?? '',
        'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        'date_of_birth': _dob?.toIso8601String(),
        'gender': _gender.text.trim().isEmpty ? null : _gender.text.trim(),
        'allergies':
            _allergies.text.trim().isEmpty ? null : _allergies.text.trim(),
        'blood_group':
            _bloodGroup.text.trim().isEmpty ? null : _bloodGroup.text.trim(),
        'emergency_contact_name': _emergencyName.text.trim().isEmpty
            ? null
            : _emergencyName.text.trim(),
        'emergency_contact_phone': _emergencyPhone.text.trim().isEmpty
            ? null
            : _emergencyPhone.text.trim(),
      });

      // Refresh local profile state.
      final updated = await SupabaseService.fetchProfile(user.id);
      if (updated != null && mounted) {
        context.read<AppState>().setProfile(UserProfile.fromMap(updated));
      }

      if (!mounted) return;
      showAppToast(context, 'Profile saved');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showAppToast(context, 'Could not save profile: $e', destructive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field(_fullName, 'Full name', Icons.badge_outlined,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null),
                const SizedBox(height: 16),
                _field(_phone, 'Phone', Icons.phone_outlined,
                    keyboardType: TextInputType.phone),
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: const Text('Date of birth'),
                    subtitle: Text(
                      _dob != null
                          ? '${_dob!.day}/${_dob!.month}/${_dob!.year}'
                          : 'Select date',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickDob,
                  ),
                ),
                const SizedBox(height: 16),
                _field(_gender, 'Gender', Icons.face_outlined),
                const SizedBox(height: 16),
                _field(_allergies, 'Allergies', Icons.medical_information_outlined),
                const SizedBox(height: 16),
                _field(_bloodGroup, 'Blood group', Icons.bloodtype_outlined),
                const SizedBox(height: 16),
                _field(_emergencyName, 'Emergency contact name',
                    Icons.emergency_outlined),
                const SizedBox(height: 16),
                _field(_emergencyPhone, 'Emergency contact phone',
                    Icons.phone_forwarded_outlined,
                    keyboardType: TextInputType.phone),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _loading ? null : _save,
                  icon: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_loading ? 'Saving…' : 'Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
      ),
      validator: validator,
    );
  }
}