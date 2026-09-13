import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/box_reading.dart';
import '../models/dose_event.dart';
import '../models/medicine_schedule.dart';
import 'alarm_sound_service.dart';
import 'mqtt_service.dart';
import 'notification_service.dart';
import 'supabase_service.dart';

/// App-level state that keeps MQTT (live hardware) in sync with Supabase
/// (single source of truth). Subscribes to the ESP32's status/event topics
/// and mirrors everything into Supabase, while exposing streams for the UI.
///
/// The schedule-edit -> firmware-sync path is made idempotent: every
/// schedule change re-publishes the FULL schedule array (replace), so the
/// firmware never sees partial diffs that could cause duplicates.
class CareCubeRepository extends ChangeNotifier {
  final MqttService _mqtt = MqttService();
  final List<StreamSubscription> _subs = [];

  String? _boxId; // supabase box id
  String? _deviceId; // ESP32 device id (carecube-xxx)

  BoxReading? _latestReading;
  DateTime? _lastSynced;

  final List<DoseEvent> _events = [];
  final List<MedicineSchedule> _schedules = [];

  bool _mqttConnected = false;

  String? get boxId => _boxId;
  String? get deviceId => _deviceId;
  BoxReading? get latestReading => _latestReading;
  DateTime? get lastSynced => _lastSynced;
  List<DoseEvent> get events => List.unmodifiable(_events);
  List<MedicineSchedule> get schedules => List.unmodifiable(_schedules);
  bool get mqttConnected => _mqttConnected;

  /// True if the most recent event is an unacknowledged reminder or
  /// emergency — mirrors the ESP32's MEDICINE_REMINDER / EMERGENCY_TAKEN
  /// states. A `taken` or `caregiver_stopped` event ends it.
  bool get hasActiveAlarm {
    if (_events.isEmpty) return false;
    return _events.first.isActiveAlarm;
  }

  Future<void> loadForPatient(String patientId) async {
    // Find the patient's box.
    final box = await SupabaseService.fetchBoxForPatient(patientId);
    if (box == null) return;
    _boxId = box['id'] as String;
    _deviceId = box['device_id'] as String;
    debugPrint('[repo] loadForPatient box=$_boxId device=$_deviceId path=$patientId');
    await _loadData();
    await _connectMqtt(_deviceId!);
  }

  /// For a caregiver: load the box of their (first) actively linked patient.
  Future<void> loadForCaregiver(String caregiverId) async {
    final links = await SupabaseService.fetchLinksForCaregiver(caregiverId);
    final active = links.where((l) => (l['status'] ?? '') == 'active').toList();
    if (active.isEmpty) return;
    final patientId = active.first['patient_id'] as String;
    await loadForPatient(patientId);
  }

  Future<void> _loadData() async {
    final boxId = _boxId;
    if (boxId == null) return;

    final schedules = await SupabaseService.fetchSchedules(boxId);
    _schedules
      ..clear()
      ..addAll(schedules.map(MedicineSchedule.fromMap));

    final events = await SupabaseService.fetchDoseEvents(boxId);
    _events
      ..clear()
      ..addAll(events.map(DoseEvent.fromMap));

    final reading = await SupabaseService.fetchLatestReading(boxId);
    _latestReading = reading == null ? null : BoxReading.fromMap(reading);

    _lastSynced = DateTime.now();
    notifyListeners();
  }

  Future<void> _connectMqtt(String deviceId) async {
    // Tear down any previous subscriptions (safe on re-init after reset).
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    _subs
      ..add(_mqtt.statusStream.listen(_onStatus))
      ..add(_mqtt.eventStream.listen(_onEvent))
      ..add(_mqtt.connectionStream.listen((c) {
        _mqttConnected = c;
        notifyListeners();
      }));

    await _mqtt.connect(deviceId);
  }

  Future<void> _onStatus(BoxReading reading) async {
    _latestReading = reading;
    _lastSynced = DateTime.now();
    notifyListeners();
    try {
      await SupabaseService.insertBoxReading(reading.toDbMap(_boxId!));
    } catch (e) {
      debugPrint('Failed to persist reading: $e');
    }
  }

  Future<void> _onEvent(DoseEvent event) async {
    _events.insert(0, event);
    if (_events.length > 200) {
      _events.removeRange(200, _events.length);
    }
    _lastSynced = DateTime.now();
    notifyListeners();

    // Phone-side alarm: ring + notify when the box starts an alarm, and
    // ring off as soon as an event resolves it (taken / stopped / missed).
    if (event.isActiveAlarm) {
      final isEmergency = event.type == 'emergency_taken';
      AlarmSoundService().startAlarm();
      NotificationService().showAlarmNotification(
        title: isEmergency ? 'Emergency dose taken' : 'Time for your dose',
        body: 'Sensor bay ${event.sensorNumber} is ringing. '
            '${isEmergency ? 'Please take the emergency dose.' : 'Please take your medicine.'}',
      );
    } else {
      AlarmSoundService().stopAlarm();
    }

    try {
      await SupabaseService.insertDoseEvent(event.toDbMap(_boxId!));
    } catch (e) {
      debugPrint('Failed to persist event: $e');
    }
  }

  /// Reload schedules, events and the latest reading from Supabase.
  /// Used by pull-to-refresh and after pairing.
  Future<void> refreshFromServer() async {
    final boxId = _boxId;
    if (boxId == null) return;

    final schedules = await SupabaseService.fetchSchedules(boxId);
    _schedules
      ..clear()
      ..addAll(schedules.map(MedicineSchedule.fromMap));

    final events = await SupabaseService.fetchDoseEvents(boxId);
    _events
      ..clear()
      ..addAll(events.map(DoseEvent.fromMap));

    final reading = await SupabaseService.fetchLatestReading(boxId);
    _latestReading = reading == null ? null : BoxReading.fromMap(reading);

    _lastSynced = DateTime.now();
    notifyListeners();
  }

  // ---- Schedule management (idempotent full-replace to firmware) ----

  Future<void> addSchedule(MedicineSchedule schedule) async {
    final boxId = _boxId;
    if (boxId == null) {
      throw StateError(
          'No box paired yet. Pair your box before adding doses.');
    }
    debugPrint('[repo] addSchedule box=$boxId slot=${schedule.slot} '
        'sensor=${schedule.sensorNumber} ${schedule.timeLabel} '
        'enabled=${schedule.enabled} label=${schedule.label}');
    await SupabaseService.insertSchedule(schedule.toDbMap(boxId));
    await _reloadSchedules();
    await _pushScheduleToFirmware();
  }

  Future<void> updateSchedule(
    String scheduleId,
    MedicineSchedule schedule,
  ) async {
    await SupabaseService.updateSchedule(
      scheduleId,
      schedule.toDbMap(_boxId!),
    );
    await _reloadSchedules();
    await _pushScheduleToFirmware();
  }

  Future<void> deleteSchedule(String scheduleId) async {
    debugPrint('[repo] deleteSchedule id=$scheduleId');
    await SupabaseService.deleteSchedule(scheduleId);
    await _reloadSchedules();
    await _pushScheduleToFirmware();
  }

  Future<void> _reloadSchedules() async {
    final fetched = await SupabaseService.fetchSchedules(_boxId!);
    debugPrint('[repo] _reloadSchedules box=$_boxId count=${fetched.length}');
    _schedules
      ..clear()
      ..addAll(fetched.map(MedicineSchedule.fromMap));
    notifyListeners();
  }

  Future<void> _pushScheduleToFirmware() async {
    _mqtt.publishSchedule(_schedules);
  }

  // ---- Caregiver action ----
  void caregiverStopAlarm() {
    _mqtt.stopAlarm();
  }

  /// Dismiss any ringing alarm and clear the on-screen alert feed.
  /// History is kept in Supabase; this only clears the local view.
  void clearAlerts() {
    if (hasActiveAlarm) {
      _mqtt.stopAlarm();
    }
    AlarmSoundService().stopAlarm();
    _events.clear();
    _lastSynced = DateTime.now();
    notifyListeners();
  }

  /// Reset for a new user/login without disposing this object so it can be
  /// re-initialized by `loadForPatient` after a role/patient change.
  Future<void> reset() async {
    AlarmSoundService().stopAlarm();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _mqtt.disconnect();
    _boxId = null;
    _deviceId = null;
    _latestReading = null;
    _lastSynced = null;
    _events.clear();
    _schedules.clear();
    _mqttConnected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _mqtt.disconnect();
    super.dispose();
  }
}
