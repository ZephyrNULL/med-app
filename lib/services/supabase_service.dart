import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../models/user_profile.dart';

/// Thin helper around the global Supabase client.
class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> init() async {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
  }

  // ---- Auth ----
  static Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) {
    return client.auth.signUp(
      email: email,
      password: password,
      data: data,
    );
  }

  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) {
    return client.auth.signInWithPassword(email: email, password: password);
  }

  static Future<void> signOut() => client.auth.signOut();

  static User? get currentUser => client.auth.currentUser;

  // ---- Profiles ----
  static Future<void> upsertProfile(Map<String, dynamic> profile) async {
    await client.from('profiles').upsert(profile);
  }

  static Future<Map<String, dynamic>?> fetchProfile(String userId) async {
    final res = await client
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    return res;
  }

  /// Returns the signed-in user's profile, re-creating the row if it was
  /// lost (e.g. after a DB reset). Rebuilds it from the auth session
  /// metadata so the app never gets stuck on a missing profile.
  static Future<UserProfile?> recoverProfileFromAuth() async {
    final u = currentUser;
    if (u == null) return null;

    final existing = await fetchProfile(u.id);
    if (existing != null) return UserProfile.fromMap(existing);

    final map = <String, dynamic>{
      'id': u.id,
      'role': (u.userMetadata?['role'] as String?) ?? 'patient',
      'full_name': (u.userMetadata?['full_name'] as String?) ??
          u.email ??
          'User',
      'email': u.email,
    };
    try {
      await upsertProfile(map);
    } catch (_) {
      // Leave the in-memory profile usable even if the row cannot be
      // persisted right now.
    }
    return UserProfile.fromMap(map);
  }

  // ---- Boxes ----
  static Future<Map<String, dynamic>?> fetchBoxForPatient(
    String patientId,
  ) async {
    final res = await client
        .from('boxes')
        .select()
        .eq('patient_id', patientId)
        .maybeSingle();
    return res;
  }

  static Future<Map<String, dynamic>> pairBox({
    required String patientId,
    required String deviceId,
  }) async {
    // Reuse the patient's existing box if present (so "connect box" is
    // just a re-point, never a duplicate), otherwise create one.
    final existing = await client
        .from('boxes')
        .select()
        .eq('patient_id', patientId)
        .maybeSingle();

    if (existing == null) {
      final res = await client
          .from('boxes')
          .insert({'patient_id': patientId, 'device_id': deviceId})
          .select()
          .single();
      return res;
    }

    await client
        .from('boxes')
        .update({'device_id': deviceId})
        .eq('id', existing['id']);
    return existing;
  }

  // ---- Schedules ----
  static Future<List<Map<String, dynamic>>> fetchSchedules(String boxId) async {
    try {
      final res = await client
          .from('schedules')
          .select()
          .eq('box_id', boxId)
          .order('hour');
      return (res as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[supabase] fetchSchedules box=$boxId error: $e');
      rethrow;
    }
  }

  static Future<void> insertSchedule(Map<String, dynamic> schedule) async {
    try {
      await client.from('schedules').insert(schedule);
      debugPrint('[supabase] insertSchedule ok box=${schedule['box_id']}');
    } catch (e) {
      // ignore: avoid_print
      print('[supabase] insertSchedule error: $e');
      rethrow;
    }
  }

  static Future<void> updateSchedule(
    String scheduleId,
    Map<String, dynamic> values,
  ) async {
    await client.from('schedules').update(values).eq('id', scheduleId);
  }

  static Future<void> deleteSchedule(String scheduleId) async {
    try {
      await client.from('schedules').delete().eq('id', scheduleId);
      debugPrint('[supabase] deleteSchedule ok id=$scheduleId');
    } catch (e) {
      // ignore: avoid_print
      print('[supabase] deleteSchedule error: $e');
      rethrow;
    }
  }

  // ---- Dose events ----
  static Future<List<Map<String, dynamic>>> fetchDoseEvents(
    String boxId, {
    int limit = 100,
  }) async {
    final res = await client
        .from('dose_events')
        .select()
        .eq('box_id', boxId)
        .order('occurred_at', ascending: false)
        .limit(limit);
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<void> insertDoseEvent(Map<String, dynamic> event) async {
    await client.from('dose_events').insert(event);
  }

  // ---- Box readings ----
  static Future<Map<String, dynamic>?> fetchLatestReading(
    String boxId,
  ) async {
    final res = await client
        .from('box_readings')
        .select()
        .eq('box_id', boxId)
        .order('recorded_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return res;
  }

  static Future<void> insertBoxReading(Map<String, dynamic> reading) async {
    await client.from('box_readings').insert(reading);
  }

  // ---- Caregiver links ----
  static Future<List<Map<String, dynamic>>> fetchLinksForCaregiver(
    String caregiverId,
  ) async {
    final res = await client
        .from('patient_caregiver_links')
        .select()
        .eq('caregiver_id', caregiverId);
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> fetchLinksForPatient(
    String patientId,
  ) async {
    final res = await client
        .from('patient_caregiver_links')
        .select()
        .eq('patient_id', patientId);
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<Map<String, dynamic>> createLink({
    required String patientId,
    required String caregiverId,
  }) async {
    final res = await client.from('patient_caregiver_links').insert({
      'patient_id': patientId,
      'caregiver_id': caregiverId,
      'status': 'active',
    }).select().single();
    return res;
  }

  // ---- Realtime helpers ----
  static Stream<List<Map<String, dynamic>>> subscribeToEvents(String boxId) {
    return client
        .from('dose_events')
        .stream(primaryKey: ['id'])
        .eq('box_id', boxId);
  }

  static Stream<List<Map<String, dynamic>>> subscribeToReadings(
    String boxId,
  ) {
    return client
        .from('box_readings')
        .stream(primaryKey: ['id'])
        .eq('box_id', boxId);
  }
}
