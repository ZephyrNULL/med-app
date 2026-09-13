import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/user_profile.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});
  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();
  String _role = 'patient';
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _fullName.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await SupabaseService.signUp(
        email: _email.text.trim(),
        password: _password.text,
        data: {
          'role': _role,
          'full_name': _fullName.text.trim(),
        },
      );
      final user = res.user;
      // A database trigger (handle_new_user) auto-creates the profile row.
      // If the signup returned a live session (email confirmation off), the
      // upsert below is guaranteed to pass RLS because auth.uid() is set;
      // if confirmation is on there is no session yet, so we skip it and
      // rely on the trigger.
      if (res.session != null && user != null) {
        await SupabaseService.upsertProfile({
          'id': user.id,
          'role': _role,
          'full_name': _fullName.text.trim(),
          'email': _email.text.trim(),
        });
      }
      if (!mounted) return;
      final state = context.read<AppState>();
      state.setProfile(UserProfile(
        id: user?.id ?? '',
        role: _role,
        fullName: _fullName.text.trim(),
        email: _email.text.trim(),
      ));
      if (_role == 'caregiver') {
        Navigator.pushReplacementNamed(context, '/setup', arguments: 'caregiver');
      } else {
        Navigator.pushReplacementNamed(context, '/setup', arguments: 'patient');
      }
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
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text(
                  'Join Care Cube',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'Set up your account to pair your box',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _fullName,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    hintText: 'Jane Smith',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    hintText: 'you@example.com',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: (v) =>
                      v == null || !v.contains('@') ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'At least 6 characters',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) =>
                      v == null || v.length < 6 ? 'Min 6 characters' : null,
                ),
                const SizedBox(height: 20),
                Text(
                  'I am a:',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Card(
                  child: RadioGroup<String>(
                    groupValue: _role,
                    onChanged: (v) => setState(() => _role = v!),
                    child: Column(
                      children: [
                        RadioListTile<String>(
                          value: 'patient',
                          title: const Text('Patient'),
                          subtitle: const Text('I take medicine from the box'),
                          secondary: const Icon(Icons.sick_outlined),
                        ),
                        const Divider(height: 1, indent: 56),
                        RadioListTile<String>(
                          value: 'caregiver',
                          title: const Text('Caregiver'),
                          subtitle: const Text('I look after someone'),
                          secondary:
                              const Icon(Icons.volunteer_activism_outlined),
                        ),
                      ],
                    ),
                  ),
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
                  onPressed: _loading ? null : _signUp,
                  icon: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const Icon(Icons.person_add_outlined),
                  label: Text(_loading ? 'Creating account…' : 'Create Account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}