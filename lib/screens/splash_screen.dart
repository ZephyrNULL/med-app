import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/supabase_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final appState = context.read<AppState>();
    final session = SupabaseService.currentUser;
    if (session != null) {
      // Load the user's profile for role; rebuild the row if it is missing
      // (e.g. after a DB reset) so the app doesn't get stuck.
      final profile = await SupabaseService.recoverProfileFromAuth();
      appState.setProfile(profile);
      final role = profile?.role;
      if (role == 'caregiver') {
        await appState.repo.loadForCaregiver(session.id);
      } else {
        await appState.repo.loadForPatient(session.id);
      }

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [scheme.primaryContainer, scheme.surface],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.4),
                      blurRadius: 32,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(Icons.medical_services_outlined,
                    size: 56, color: Colors.white),
              ),
              const SizedBox(height: 26),
              Text(
                'Care Cube',
                style: textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.onPrimaryContainer,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 42),
              const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}