import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/main_shell.dart';
import 'screens/role_selection_screen.dart';
import 'screens/setup_wizard_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/sign_up_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/verify_email_screen.dart';
import 'services/alarm_sound_service.dart';
import 'services/app_state.dart';
import 'services/notification_service.dart';
import 'services/supabase_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SupabaseService.init();
  await NotificationService().init();
  await AlarmSoundService().init();

  runApp(const CareCubeApp());
}

class CareCubeApp extends StatelessWidget {
  const CareCubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        title: 'Care Cube',
        theme: AppTheme.light,
        initialRoute: '/',
        routes: {
          '/': (_) => const SplashScreen(),
          '/login': (_) => const SignInScreen(),
          '/signup': (_) => const SignUpScreen(),
          '/roles': (_) => const RoleSelectionScreen(),
          '/home': (_) => const MainShell(),
        },
        onGenerateRoute: (settings) {
          // '/verify' carries the signup email argument.
          if (settings.name == '/verify') {
            return MaterialPageRoute(
              builder: (_) =>
                  VerifyEmailScreen(email: settings.arguments as String?),
            );
          }
          // '/setup' carries a role argument.
          if (settings.name == '/setup') {
            final role = (settings.arguments as String?) ?? 'patient';
            return MaterialPageRoute(
              builder: (_) => SetupWizardScreen(role: role),
            );
          }
          return null;
        },
      ),
    );
  }
}