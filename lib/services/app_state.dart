import 'package:flutter/material.dart';

import '../models/user_profile.dart';
import '../services/care_cube_repository.dart';
import '../services/supabase_service.dart';

/// Holds the signed-in user's role + profile and the active repo.
/// Provided at the top of the widget tree so screens can read role without
/// prop-drilling.
class AppState extends ChangeNotifier {
  UserProfile? profile;
  String? role; // 'patient' | 'caregiver'
  final CareCubeRepository repo = CareCubeRepository();

  AppState() {
    // Schedules/readings/events are owned by the repo (a separate
    // ChangeNotifier). Forward its notifications so every screen that
    // watches AppState also rebuilds when the repo changes.
    repo.addListener(_syncRepo);
  }

  void _syncRepo() => notifyListeners();

  @override
  void dispose() {
    repo.removeListener(_syncRepo);
    repo.dispose();
    super.dispose();
  }

  bool get isCaregiver => role == 'caregiver';
  bool get isPatient => role == 'patient';

  void setProfile(UserProfile? p) {
    profile = p;
    role = p?.role;
    notifyListeners();
  }

  /// Re-fetch the profile from Supabase and update the local model.
  Future<void> reloadProfile() async {
    final id = SupabaseService.currentUser?.id ?? profile?.id;
    if (id == null) return;
    final data = await SupabaseService.fetchProfile(id);
    if (data != null) {
      setProfile(UserProfile.fromMap(data));
      return;
    }
    // Profile row missing (e.g. DB reset) — rebuild it from the session.
    final recovered = await SupabaseService.recoverProfileFromAuth();
    if (recovered != null) setProfile(recovered);
  }

  Future<void> clear() async {
    profile = null;
    role = null;
    await repo.reset();
  }
}
