import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/supabase_service.dart';

/// Handles first-run onboarding after signup:
///  - patient:  pair their box (enter device_id)
///  - caregiver: link to a patient (enter patient email)
class SetupWizardScreen extends StatefulWidget {
  final String role;
  const SetupWizardScreen({super.key, required this.role});
  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  final _caregiverEmail = TextEditingController();
  final _deviceId = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _caregiverEmail.dispose();
    _deviceId.dispose();
    super.dispose();
  }

  Future<void> _finishPatient() async {
    final appState = context.read<AppState>();
    final user = SupabaseService.currentUser;
    if (user == null) return;

    final deviceId = _deviceId.text.trim();
    if (deviceId.isEmpty) {
      setState(() => _error = 'Enter your box device ID');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await SupabaseService.pairBox(patientId: user.id, deviceId: deviceId);
      await appState.repo.loadForPatient(user.id);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _finishCaregiver() async {
    final appState = context.read<AppState>();
    final user = SupabaseService.currentUser;
    if (user == null) return;

    final patientEmail = _caregiverEmail.text.trim();
    if (patientEmail.isEmpty) {
      setState(() => _error = 'Enter the patient\u2019s email');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Look up the patient by email (must have a profile).
      final patientProfiles =
          await SupabaseService.client.from('profiles').select().eq(
                'email',
                patientEmail,
              ).eq('role', 'patient');
      if ((patientProfiles as List).isEmpty) {
        if (!mounted) return;
        setState(() {
          _error = 'No patient found with that email';
          _loading = false;
        });
        return;
      }
      final patientId = (patientProfiles.first as Map)['id'] as String;
      await SupabaseService.createLink(
        patientId: patientId,
        caregiverId: user.id,
      );
      await appState.repo.loadForCaregiver(user.id);
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPatient = widget.role == 'patient';
    return Scaffold(
      appBar: AppBar(
        title: Text(isPatient ? 'Pair your box' : 'Link a patient'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(20),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPatient
                      ? Icons.medical_information_outlined
                      : Icons.link_outlined,
                  size: 48,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isPatient
                    ? 'Enter your Care Cube device ID'
                    : 'Enter the email of the patient you care for',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),
              if (isPatient)
                TextFormField(
                  controller: _deviceId,
                  decoration: const InputDecoration(
                    labelText: 'Device ID',
                    hintText: 'carecube-001',
                    prefixIcon: Icon(Icons.qr_code_scanner),
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
                )
              else
                TextFormField(
                  controller: _caregiverEmail,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Patient email',
                    hintText: 'patient@example.com',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) =>
                      v == null || !v.contains('@') ? 'Enter a valid email' : null,
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _loading
                    ? null
                    : isPatient
                        ? _finishPatient
                        : _finishCaregiver,
                icon: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.check),
                label: Text(_loading
                    ? 'Connecting…'
                    : isPatient
                        ? 'Done'
                        : 'Link'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _loading
                    ? null
                    : () => Navigator.pushReplacementNamed(context, '/home'),
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}