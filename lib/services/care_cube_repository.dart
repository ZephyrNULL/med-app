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

  /// Phone-local alarm scheduler so doses still ring even when the box
  /// (or the Wokwi sim) is offline. Scans enabled schedules every tick.
  Timer? _scheduleTimer;

  /// How late a dose may still ring on the phone. The previous design only
  /// matched an exact hour/minute on a 20s timer, so any drift, a timer
  /// delayed by Android doze, or the app being resumed late meant the dose
  /// was silently skipped for the whole day.
  static const _doseCatchUp = Duration(minutes: 30);

  /// How often a live reading is written to the cloud. The box now publishes
  /// the environment every couple of seconds, so persisting on every message
  /// would add tens of thousands of rows a day; the UI still updates live.
  static const _readingPersistInterval = Duration(minutes: 1);

  DateTime? _lastReadingPersistAt;

  /// Drives the "updated Ns ago" freshness label. Publishing does not
  /// generate its own rebuild once the box goes quiet, so a slow tick keeps
  /// a stale reading from looking current.
  Timer? _freshnessTimer;

  /// Per-schedule "already rang today" keys ("yyyy-M-d|slot") so the scan
  /// stays idempotent per dose per day.
  final Set<String> _localAlarmKeys = {};

  /// Bay number of the alarm the phone is currently ringing for. A
  /// resolution event only stops the alarm when it refers to this bay,
  /// instead of any event silencing any alarm.
  int? _activeAlarmBay;

  /// Bay number of the outstanding wrong-bay warning, if any. Kept on a
  /// SEPARATE channel from [_activeAlarmBay] so a wrong-bay alarm can never
  /// mask (or be mistaken for) a reminder banner below it in the feed.
  int? _wrongBayAlertBay;

  /// How long a wrong-bay warning restored from the database may still ring
  /// for. The box publishes `wrong_bay_taken` when the warning starts and
  /// `wrong_bay_returned` the moment the container is back, so an older row
  /// is history, not a live alarm.
  static const _wrongBayAlarmMaxAge = Duration(minutes: 30);

  String? get boxId => _boxId;
  String? get deviceId => _deviceId;
  BoxReading? get latestReading => _latestReading;
  DateTime? get lastSynced => _lastSynced;
  List<DoseEvent> get events => List.unmodifiable(_events);
  List<MedicineSchedule> get schedules => List.unmodifiable(_schedules);
  bool get mqttConnected => _mqttConnected;

  /// When the box last pushed an environment reading. Deliberately separate
  /// from [lastSynced]: a dose event or a server refresh bumps that one, and
  /// reusing it would relabel a stale temperature as "just now".
  DateTime? _lastReadingAt;

  /// When the box last made live contact over MQTT (a status OR an event).
  /// Only live messages update this, so a value restored from Supabase after
  /// a restart never makes a powered-off box look online.
  DateTime? _lastBoxContactAt;

  /// Tracks the previous [boxOnline] value so the freshness timer can react
  /// to the box dropping off the network.
  bool _wasOnline = false;

  /// How long ago the box last reported its environment, or null if it never
  /// has since this session started. A reading older than [_staleAfter] is
  /// shown as stale rather than presented as if it were live.
  Duration? get readingAge {
    final at = _lastReadingAt;
    if (_latestReading == null || at == null) return null;
    return DateTime.now().difference(at);
  }

  static const _staleAfter = Duration(seconds: 20);

  bool get isReadingStale {
    final age = readingAge;
    return age == null || age > _staleAfter;
  }

  /// True only while the box is actually reporting live. Readings, events
  /// and schedules restored from Supabase on startup are persisted history,
  /// not a live feed, so a box that is powered off must not present itself
  /// as online.
  bool get boxOnline {
    final at = _lastBoxContactAt;
    return at != null && DateTime.now().difference(at) <= _staleAfter;
  }

  /// The most recent event that actually represents an alarm state: an
  /// active reminder/emergency or a resolution of one. Purely informational
  /// events (the wrong-bay warning pair) are skipped, so a wrong-bay warning
  /// landing on top of an outstanding reminder cannot hide the alarm banner
  /// or make [hasActiveAlarm] report false.
  ///
  /// A `reminder_started` with no enabled schedule for its bay is stale
  /// history (the dose was deleted, or the row predates a reset) - the box
  /// only ever rings scheduled bays - so it is skipped as well. Without the
  /// guard, an unresolved row restored from Supabase became a phantom
  /// "MEDICINE ALARM ACTIVE" banner (and phone ring) the moment the app
  /// connected, with no schedule anywhere to justify it.
  DoseEvent? get _latestAlarmStateEvent {
    for (final e in _events) {
      if (e.isInformational) continue;
      if (e.type == 'reminder_started' && !_hasEnabledSchedule(e.sensorNumber)) {
        continue;
      }
      return e;
    }
    return null;
  }

  bool _hasEnabledSchedule(int sensorNumber) =>
      _schedules.any((s) => s.sensorNumber == sensorNumber && s.enabled);

  /// True if the most recent alarm-state event is an unacknowledged reminder
  /// or emergency — mirrors the ESP32's MEDICINE_REMINDER / EMERGENCY_TAKEN
  /// states. A `taken`, `caregiver_stopped` or `missed` event ends it.
  bool get hasActiveAlarm => _latestAlarmStateEvent?.isActiveAlarm ?? false;

  /// UI-facing alarm state: a reminder only counts as active while the box
  /// that fired it is live. An unresolved event restored from the DB must
  /// not keep a phantom banner (or ring) alive after the box is gone.
  bool get showActiveAlarm => boxOnline && hasActiveAlarm;

  /// The event currently ringing (the most recent alarm-state event while it
  /// is unresolved).
  DoseEvent? get activeAlarmEvent {
    final e = _latestAlarmStateEvent;
    return (e != null && e.isActiveAlarm) ? e : null;
  }

  /// True while the ringing alarm is an emergency (bay 7 taken). Drives the
  /// red "Emergency Taken" banner.
  bool get isEmergencyAlarm => activeAlarmEvent?.type == 'emergency_taken';

  /// True while a wrong-bay warning is live: the box reported one and has
  /// not yet reported the container back (or the correct dose taken, or a
  /// caregiver stop). Gated on the box being online, like [showActiveAlarm],
  /// so a stored row cannot ring for a powered-off box.
  bool get showWrongBayAlarm => boxOnline && _wrongBayAlertBay != null;

  int? get wrongBayAlertBay => _wrongBayAlertBay;

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
    _syncActiveAlarmBay();
    _syncWrongBayAlarm();

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
        // On (re)connect, re-push the current schedule so the firmware's
        // copy stays in sync even if it was offline when doses changed.
        // ALWAYS push, even when the list is empty: the firmware boots with
        // all six bays enabled at hardcoded times, and an empty push is what
        // disables them. The old `isNotEmpty` guard meant a box with no
        // schedules ever got told, so it rang phantom alarms all day.
        if (c) {
          _mqtt.publishSchedule(_schedules);
        }
      }));

    await _mqtt.connect(deviceId);
    _startScheduleScanner();
  }

  /// Polls enabled schedules and rings for any dose that has come due and
  /// has not already rung today. Runs on a short interval and on resume.
  void _startScheduleScanner() {
    _scheduleTimer?.cancel();
    _scanSchedules();
    _scheduleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _scanSchedules();
    });

    _freshnessTimer?.cancel();
    _freshnessTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final online = boxOnline;
      if (_wasOnline && !online) {
        // The box stopped reporting while an alarm looked active. That is
        // stored history, not a live alert, so silence it and drop the
        // banner until the box reports again.
        debugPrint('[repo] box offline - clearing live alarm state');
        _activeAlarmBay = null;
        _wrongBayAlertBay = null;
        AlarmSoundService().stopAlarm();
      }
      if (!_wasOnline && online) {
        // The box just came back. Anything we published while it was away
        // (its timezone, most importantly) never reached it.
        debugPrint('[repo] box online - re-publishing timezone');
        _mqtt.publishTimeZone();
      }
      _wasOnline = online;
      if (_latestReading != null || _events.isNotEmpty) notifyListeners();
    });
  }

  /// Re-check after the app comes back to the foreground. Timers are
  /// throttled or paused while backgrounded, so a dose reached in the
  /// background has to be picked up here - but only after the feed is
  /// re-read, otherwise a dose taken while away would still be ringing.
  Future<void> onAppResumed() async {
    try {
      await refreshFromServer();
    } catch (e) {
      debugPrint('Resume refresh failed: $e');
    }
    _scanSchedules();
    if ((showActiveAlarm || showWrongBayAlarm) &&
        !AlarmSoundService().isRinging) {
      AlarmSoundService().startAlarm();
    }
  }

  void _scanSchedules() {
    // The phone-side scanner is a backup for a live box. When the box is not
    // reporting there is nothing to remind against locally, so a stale
    // schedule must not fire a phantom alarm.
    if (_deviceId == null || _schedules.isEmpty || !boxOnline) return;

    final now = DateTime.now();

    for (final s in _schedules) {
      if (!s.enabled) continue;

      final due = DateTime(now.year, now.month, now.day, s.hour, s.minute);
      if (now.isBefore(due)) continue;
      if (now.difference(due) > _doseCatchUp) continue;

      final key = '${now.year}-${now.month}-${now.day}|${s.slot}';
      if (!_localAlarmKeys.add(key)) continue; // already rang today

      // Already handled today: taking the dose, a caregiver stopping the
      // alarm, or the box missing the dose all end today's obligation. A
      // late re-fire after that would be a phantom alarm (e.g. the app
      // restarts within the catch-up window after the caregiver stopped).
      final alreadyHandled = _events.any((e) =>
          (e.type == 'taken' ||
              e.type == 'caregiver_stopped' ||
              e.type == 'missed') &&
          e.sensorNumber == s.sensorNumber &&
          _isSameDay(e.occurredAt, now));
      if (alreadyHandled) continue;

      // The box already reported this reminder; ringing again would double
      // up on the phone and insert a duplicate row.
      final ringing = activeAlarmEvent;
      if (ringing != null && ringing.sensorNumber == s.sensorNumber) {
        debugPrint('[repo] local dose already ringing sensor=${s.sensorNumber}');
        continue;
      }

      debugPrint('[repo] local dose alarm sensor=${s.sensorNumber} '
          'at ${s.timeLabel} (late ${now.difference(due).inSeconds}s)');
      _handleLocalEvent(
        DoseEvent(
          type: 'reminder_started',
          sensorNumber: s.sensorNumber,
          occurredAt: DateTime.now(),
        ),
      );
    }
  }

  bool _isSameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  Future<void> _onStatus(BoxReading reading) async {
    _latestReading = reading;
    _lastSynced = DateTime.now();
    _lastReadingAt = _lastSynced;
    _lastBoxContactAt = _lastSynced;
    notifyListeners();

    final boxId = _boxId;
    if (boxId == null) return;

    final now = DateTime.now();
    if (_lastReadingPersistAt != null &&
        now.difference(_lastReadingPersistAt!) < _readingPersistInterval) {
      return;
    }
    _lastReadingPersistAt = now;

    try {
      await SupabaseService.insertBoxReading(reading.toDbMap(boxId));
    } catch (e) {
      debugPrint('Failed to persist reading: $e');
    }
  }

  Future<void> _onEvent(DoseEvent event) async {
    // A live event is proof the box is on, even before its next status
    // heartbeat lands.
    _lastBoxContactAt = DateTime.now();
    _handleLocalEvent(event, persist: true);
  }

  /// Shared handler for incoming (MQTT) and locally-originated events:
  /// updates the feed, drives the phone alarm + notification, and
  /// optionally mirrors the event into Supabase.
  void _handleLocalEvent(DoseEvent event, {bool persist = false}) {
    // Informational events (a medicine removed from a bay with no dose due)
    // only annotate the feed. They are not an alarm and do not resolve one,
    // so they must never ring or silence the phone, clear schedules, or
    // change the tracked ringing bay.
    if (event.isInformational) {
      final isDuplicateInfo = _events.isNotEmpty &&
          _events.first.type == event.type &&
          _events.first.sensorNumber == event.sensorNumber &&
          DateTime.now().difference(_events.first.occurredAt).abs() <
              const Duration(seconds: 30);
      if (!isDuplicateInfo) {
        _events.insert(0, event);
        if (_events.length > 200) {
          _events.removeRange(200, _events.length);
        }
        _lastSynced = DateTime.now();
        notifyListeners();
        if (event.isWrongBayAlert) {
          NotificationService().showAlarmNotification(
            title: 'Medicine removed from the wrong bay',
            body: 'The dose in '
                '${MedicineSchedule.labelForBay(event.sensorNumber)} was '
                'removed unexpectedly. Put the container back in the box.',
          );
        }
      }

      // The wrong-bay warning runs on its OWN alarm channel: a live warning
      // rings the phone and shows its banner, and its resolution (container
      // put back) ends both - but only for that bay, and never while a
      // reminder/emergency is still ringing (the sound is shared).
      if (event.isWrongBayAlert) {
        _wrongBayAlertBay = event.sensorNumber;
        if (!AlarmSoundService().isRinging) {
          AlarmSoundService().startAlarm();
        }
        notifyListeners();
      } else if (event.isWrongBayResolved &&
          _wrongBayAlertBay == event.sensorNumber) {
        _wrongBayAlertBay = null;
        if (_activeAlarmBay == null) {
          AlarmSoundService().stopAlarm();
        }
        notifyListeners();
      }

      if (persist && _boxId != null && !isDuplicateInfo) {
        SupabaseService.insertDoseEvent(event.toDbMap(_boxId!))
            .catchError((e) {
          debugPrint('Failed to persist event: $e');
        });
      }
      return;
    }

    // The box repeats `reminder_started` while a dose is still outstanding
    // (so a phone that missed the first event rings again). Repeats must
    // not stack up in the feed as if they were separate doses. Compare
    // against the latest alarm-state event, not the feed head, because an
    // informational event may be sitting above it.
    final alarmState = _latestAlarmStateEvent;
    final isRepeat = event.isActiveAlarm &&
        hasActiveAlarm &&
        _activeAlarmBay == event.sensorNumber &&
        alarmState?.type == event.type;

    // A `caregiver_stopped` echo of a stop we already applied locally must
    // not appear twice in the feed. The echo is still persisted (below); it
    // only skips the duplicate feed row.
    final isDuplicateResolution = !event.isActiveAlarm &&
        event.type == 'caregiver_stopped' &&
        _events.any((e) =>
            e.type == 'caregiver_stopped' &&
            e.sensorNumber == event.sensorNumber &&
            DateTime.now().difference(e.occurredAt).abs() <
                const Duration(seconds: 30));

    if (!isRepeat && !isDuplicateResolution) {
      _events.insert(0, event);
      if (_events.length > 200) {
        _events.removeRange(200, _events.length);
      }
      _lastSynced = DateTime.now();
      notifyListeners();
    }

    // Note: a resolution event intentionally does NOT clear the per-day
    // local-ring key. Clearing it let the phone's own scanner re-fire the
    // same dose for the rest of the catch-up window (a "phantom" alarm
    // several minutes after the box's alarm was stopped). Keys are
    // date-scoped (`yyyy-m-d|slot`) so they naturally reset each day, and
    // stay set once a dose has rung so it never rings twice in one day.

    // Phone-side alarm: ring + notify when the box starts an alarm, and
    // ring off as soon as an event resolves it (taken / stopped / missed).
    if (event.isActiveAlarm) {
      _activeAlarmBay = event.sensorNumber;
      final isEmergency = event.type == 'emergency_taken';
      if (!AlarmSoundService().isRinging) {
        AlarmSoundService().startAlarm();
      } else if (isRepeat) {
        // Already ringing - make sure it has not gone quiet.
        AlarmSoundService().startAlarm();
      }
      NotificationService().showAlarmNotification(
        title: isEmergency ? 'Emergency dose taken' : 'Time for your dose',
        body: '${MedicineSchedule.labelForBay(event.sensorNumber)} is ringing. '
            '${isEmergency ? 'Please take the emergency dose.' : 'Please take your medicine.'}',
      );
    } else {
      // Only an event about the bay that is actually ringing may silence
      // it. Previously any non-alarm event stopped every alarm, so an
      // unrelated `taken` arriving out of order cut a live alarm short.
      final stopsCurrentAlarm = _activeAlarmBay == null ||
          _activeAlarmBay == event.sensorNumber ||
          event.type == 'caregiver_stopped';

      // A caregiver stop (any bay) or the correct dose being taken also
      // resolves an outstanding wrong-bay warning for that bay - the box
      // publishes `wrong_bay_returned` too, but the local resolution keeps
      // the phone honest even if that event is delayed or lost.
      if (event.type == 'caregiver_stopped' ||
          (event.type == 'taken' && _wrongBayAlertBay == event.sensorNumber)) {
        _wrongBayAlertBay = null;
      }

      if (stopsCurrentAlarm) {
        _activeAlarmBay = null;
        // Silence only when nothing else is still outstanding: a wrong-bay
        // warning on another bay must keep the phone ringing.
        if (_wrongBayAlertBay == null) {
          AlarmSoundService().stopAlarm();
        }
      }

      // The dose is now handled (taken or stopped): its schedule has
      // served its purpose. Remove it automatically so the medicine list
      // only shows still-pending doses and the box stops scheduling it.
      if (event.type == 'taken' || event.type == 'caregiver_stopped') {
        _maybeAutoRemoveSchedule(event.sensorNumber);
      }
    }

    if (persist && _boxId != null && !isRepeat) {
      SupabaseService.insertDoseEvent(event.toDbMap(_boxId!))
          .catchError((e) {
        debugPrint('Failed to persist event: $e');
      });
    }
  }

  /// Re-derive which bay is ringing from the latest alarm-state event. Used
  /// after the feed is (re)loaded so a restart or a refresh does not lose
  /// track of an alarm that is still outstanding.
  void _syncActiveAlarmBay() {
    _activeAlarmBay = activeAlarmEvent?.sensorNumber;
  }

  /// Re-derive the wrong-bay warning from the reloaded feed. Only a RECENT,
  /// unresolved `wrong_bay_taken` may ring: the box publishes
  /// `wrong_bay_returned` the moment the container is back, so anything
  /// older than [_wrongBayAlarmMaxAge] is just history. The feed is
  /// newest-first, so the first wrong-bay event decides.
  void _syncWrongBayAlarm() {
    int? bay;
    for (final e in _events) {
      if (e.isWrongBayResolved) {
        if (bay == e.sensorNumber) bay = null;
        break;
      }
      if (e.isWrongBayAlert) {
        if (DateTime.now().difference(e.occurredAt) <= _wrongBayAlarmMaxAge) {
          bay = e.sensorNumber;
        }
        break;
      }
    }
    _wrongBayAlertBay = bay;
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
    _syncActiveAlarmBay();
    _syncWrongBayAlarm();

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

  /// Automatically remove the schedule for a bay whose dose has just been
  /// handled (taken or caregiver-stopped). One schedule per compartment, so
  /// the sensor number uniquely identifies it. Failures are non-fatal: the
  /// reminder simply stays and the caregiver can delete it manually.
  void _maybeAutoRemoveSchedule(int sensorNumber) {
    for (final s in _schedules) {
      if (s.sensorNumber == sensorNumber && s.id != null) {
        debugPrint('[repo] auto-remove resolved schedule id=${s.id} '
            'sensor=$sensorNumber ${s.bayLabel} ${s.timeLabel}');
        deleteSchedule(s.id!).catchError((e) {
          debugPrint('Failed to auto-remove schedule: $e');
        });
        return;
      }
    }
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
    _mqtt.publishTimeZone();
    _mqtt.publishSchedule(_schedules);
  }

  // ---- Caregiver action ----
  /// Caregiver-initiated stop. Silences the buzzer and this phone and
  /// resolves the outstanding alarm in the feed *immediately*, then tells the
  /// firmware to stop.
  ///
  /// The resolution is applied locally rather than waiting on the box's
  /// `caregiver_stopped` echo. The box only echoes when *its* alarm was
  /// ringing, so a phone-local reminder (fired by the scanner while the box
  /// is quiet) produced no echo at all - the Stop button sent `alarm/stop`
  /// into the void and the banner rang forever. When the box genuinely is
  /// ringing it still echoes `caregiver_stopped`, which is de-duplicated out
  /// of the feed against this row and persists the resolution. This is the
  /// only path other than actually taking the dose that ends an alarm.
  void caregiverStopAlarm() {
    _mqtt.stopAlarm();
    // The stop silences the box's wrong-bay warning too (it publishes
    // caregiver_stopped for that bay), so drop the local state now.
    _wrongBayAlertBay = null;

    final active = activeAlarmEvent;
    if (active != null) {
      _handleLocalEvent(
        DoseEvent(
          type: 'caregiver_stopped',
          sensorNumber: active.sensorNumber,
          occurredAt: DateTime.now(),
        ),
      );
    } else {
      _activeAlarmBay = null;
      AlarmSoundService().stopAlarm();
      notifyListeners();
    }
  }

  /// Clear the local view of the alert feed. History is kept in Supabase.
  ///
  /// Deliberately does NOT stop a ringing alarm or publish `alarm/stop`:
  /// the buzzer and phone alarm may only be silenced by taking the dose or
  /// by a caregiver. The outstanding alarm event is kept at the head of the
  /// feed so its banner and the ringing continue on the patient side.
  void clearAlerts() {
    final active = activeAlarmEvent;
    _events.clear();
    if (active != null) _events.add(active);
    _lastSynced = DateTime.now();
    notifyListeners();
  }

  /// Reset for a new user/login without disposing this object so it can be
  /// re-initialized by `loadForPatient` after a role/patient change.
  Future<void> reset() async {
    AlarmSoundService().stopAlarm();
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _lastReadingPersistAt = null;
    _localAlarmKeys.clear();
    _activeAlarmBay = null;
    _wrongBayAlertBay = null;
    _lastReadingAt = null;
    _lastBoxContactAt = null;
    _wasOnline = false;
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
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    _localAlarmKeys.clear();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _mqtt.disconnect();
    super.dispose();
  }
}
