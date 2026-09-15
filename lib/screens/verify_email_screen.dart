import 'package:flutter/material.dart';

/// Shown after signup when email confirmation is enabled and no live
/// session exists yet. The user must click the link in the email before
/// they can sign in — no automatic login.
class VerifyEmailScreen extends StatelessWidget {
  final String? email;
  const VerifyEmailScreen({super.key, this.email});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm your email')),
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
                child: Icon(Icons.mark_email_read_outlined,
                    size: 52, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(height: 20),
              Text(
                'Check your inbox',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                email != null && email!.isNotEmpty
                    ? 'We sent a confirmation link to $email.\n'
                        'Click it to activate your account, then sign in.'
                    : 'We sent you a confirmation link.\n'
                        'Click it to activate your account, then sign in.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/login',
                  (route) => false,
                ),
                icon: const Icon(Icons.login),
                label: const Text('Go to sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}