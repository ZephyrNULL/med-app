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

  /// The alarm the phone is currently ringing for, if any. The box's status
  /// heartbeat is authoritative while the box is online (reconciled on every
  /// beat); live events drive it too. It is NEVER restored from the Supabase
  /// feed on startup: resolutions published while the app was closed never
  /// reach Supabase, so feed rows are history and would resurrect phantom
  /// alarms forever.
  DoseEvent? _activeAlarm;

  /// True when [_activeAlarm] originated on the phone (its own schedule
  /// scanner) rather than from a box event. A "box is quiet" status beat
  /// must not silence a phone-local alarm, so this flag guards reconciliation.
  bool _activeAlarmIsLocal = false;

  /// When the current [_activeAlarm] started ringing. A status beat older
  /// than this must not clear a fresh alarm: the beat may have been
  /// published before the box started ringing but delivered afterwards
  /// (status and event are separate MQTT topics with no ordering between
  /// them).
  DateTime? _alarmRangAt;

  /// When a reminder/emergency alarm was last resolved (taken, stopped or
  /// missed). A status beat older than this must not re-adopt an alarm the
  /// phone has already resolved locally.
  DateTime? _alarmResolvedAt;

  /// When the wrong-bay warning started / was resolved - the same
  /// grace-window bookkeeping as [_alarmRangAt] / [_alarmResolvedAt], on the
  /// separate wrong-bay channel.
  DateTime? _wrongBayRangAt;
  DateTime? _wrongBayResolvedAt;

  /// Bay number of the outstanding wrong-bay warning, if any. Kept on a
  /// SEPARATE channel from [_activeAlarm] so a wrong-bay alarm can never
  /// mask (or be mistaken for) a reminder banner below it in the feed.
  int? _wrongBayAlertBay;

  /// Box-reported bitmask of schedule slots whose dose has been triggered
  /// today (bit 0 = slot 0). Lets the phone scanner skip a dose the box
  /// already rang for while the app was closed - the root cause of the
  /// phantom ring on app open. Null when the firmware is older and does not
  /// publish it.
  int? _boxDoseTriggeredMask;

  /// How long after an alarm rang/was resolved the phone keeps ignoring the
  /// opposite signal from the box's status heartbeat. Status and event
  /// messages travel on separate MQTT topics, so a beat published before the
  /// box started ringing (or before it stopped) can arrive just after the
  /// event - the window lets the event win.
  static const _reconcileGrace = Duration(seconds: 5);

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

  /// True while any reminder/emergency alarm is outstanding. Derived from
  /// [_activeAlarm], which the box's status heartbeat keeps reconciled
  /// while the box is online; never from the Supabase feed.
  bool get hasActiveAlarm => _activeAlarm != null;

  /// UI-facing alarm state: a reminder only counts as active while the box
  /// that fired it is live.
  bool get showActiveAlarm => boxOnline && hasActiveAlarm;

  /// The event currently ringing, if any.
  DoseEvent? get activeAlarmEvent => _activeAlarm;

  /// True while the ringing alarm is an emergency (bay 7 taken). Drives the
  /// red "Emergency Taken" banner.
  bool get isEmergencyAlarm => _activeAlarm?.type == 'emergency_taken';

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
    // Deliberately no alarm-state restore from the feed: rows are history,
    // and resolutions published while the app was closed never reach
    // Supabase, so a restored row can outlive the real alarm forever. Live
    // alarm state is reconciled from the box's status heartbeat instead.

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
        _activeAlarm = null;
        _activeAlarmIsLocal = false;
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
  /// background has to be picked up here - after the box's status heartbeat
  /// has had a chance to reconcile alarm state, so a dose taken while away
  /// is not still ringing.
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
    } else if (_activeAlarm == null &&
        _wrongBayAlertBay == null &&
        AlarmSoundService().isRinging) {
      // Everything was resolved while the app was away (the box reconciled
      // it via the status heartbeat); do not keep ringing.
      AlarmSoundService().stopAlarm();
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

      // The box already rang this dose while the app was closed: its status
      // heartbeat carries the bit-mask of slots triggered today. Ringing
      // again here would be the phantom "alarm on app open" - a dose the
      // patient already took (or that is still ringing on the box, which
      // reports its own alarm state separately).
      final mask = _boxDoseTriggeredMask;
      if (mask != null && (mask & (1 << s.slot)) != 0) {
        debugPrint('[repo] box already triggered sensor=${s.sensorNumber} '
            'slot=${s.slot} - skipping local ring');
        continue;
      }

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
        local: true,
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
    _reconcileWithBoxAlarmState(reading);
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
  /// optionally mirrors the event into Supabase. [local] marks events
  /// originated by the phone's own scanner so a "box is quiet" status beat
  /// never silences them during reconciliation.
  void _handleLocalEvent(DoseEvent event, {bool persist = false, bool local = false}) {
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
            id: 2,
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
      // reminder/emergency is still ringing (the sound is shared). The
      // rang/resolved timestamps let the status heartbeat reconcile this
      // state without racing events that travel on the other MQTT topic.
      if (event.isWrongBayAlert) {
        _wrongBayAlertBay = event.sensorNumber;
        _wrongBayRangAt = DateTime.now();
        if (!AlarmSoundService().isRinging) {
          AlarmSoundService().startAlarm();
        }
        notifyListeners();
      } else if (event.isWrongBayResolved) {
        _wrongBayResolvedAt = DateTime.now();
        if (_wrongBayAlertBay == event.sensorNumber) {
          _wrongBayAlertBay = null;
          if (_activeAlarm == null) {
            AlarmSoundService().stopAlarm();
          }
          notifyListeners();
        }
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
    // against the tracked alarm, not the feed, because the feed is history.
    final isRepeat = event.isActiveAlarm &&
        _activeAlarm != null &&
        _activeAlarm!.sensorNumber == event.sensorNumber &&
        _activeAlarm!.type == event.type;

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
      _activeAlarm = event;
      _activeAlarmIsLocal = local;
      _alarmRangAt = DateTime.now();
      final isEmergency = event.type == 'emergency_taken';
      if (!AlarmSoundService().isRinging || isRepeat) {
        // Start it, or make sure an already-ringing alarm has not gone
        // quiet (the box re-publishes reminder events as a keep-alive).
        AlarmSoundService().startAlarm();
      }
      NotificationService().showAlarmNotification(
        id: isEmergency ? 3 : 1,
        title: isEmergency ? 'Emergency dose taken' : 'Time for your dose',
        body: '${MedicineSchedule.labelForBay(event.sensorNumber)} is ringing. '
            '${isEmergency ? 'Please take the emergency dose.' : 'Please take your medicine.'}',
      );
    } else {
      // Every resolved event (taken / missed / stopped / emergency returned)
      // records when the alarm ended, so a status beat that was published
      // before this resolution (and arrives late on the other MQTT topic)
      // cannot re-adopt the alarm during the grace window.
      _alarmResolvedAt = DateTime.now();

      // Only an event about the bay that is actually ringing may silence
      // it. Previously any non-alarm event stopped every alarm, so an
      // unrelated `taken` arriving out of order cut a live alarm short.
      final stopsCurrentAlarm = _activeAlarm == null ||
          _activeAlarm!.sensorNumber == event.sensorNumber ||
          event.type == 'caregiver_stopped';

      // A caregiver stop (any bay) or the correct dose being taken also
      // resolves an outstanding wrong-bay warning for that bay - the box
      // publishes `wrong_bay_returned` too, but the local resolution keeps
      // the phone honest even if that event is delayed or lost.
      if (event.type == 'caregiver_stopped' ||
          (event.type == 'taken' && _wrongBayAlertBay == event.sensorNumber)) {
        _wrongBayAlertBay = null;
        _wrongBayResolvedAt = DateTime.now();
      }

      if (stopsCurrentAlarm) {
        _activeAlarm = null;
        _activeAlarmIsLocal = false;
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

  /// Reconciles the phone's live alarm state with the box's status
  /// heartbeat - the authoritative alarm state while the box is online.
  /// Events are only persisted by the phone over MQTT, so resolutions
  /// published while the app was closed never reach Supabase and the feed
  /// can never be trusted to restore a live alarm; the box's own state can.
  ///
  /// Grace windows ([_reconcileGrace]) keep a status beat that was published
  /// BEFORE the box started (or stopped) ringing from racing the matching
  /// event message on the other MQTT topic.
  void _reconcileWithBoxAlarmState(BoxReading reading) {
    final reminder = reading.reminderSensor;
    final wrongBay = reading.wrongBaySensor;
    final emergency = reading.emergencyActive;
    final mask = reading.doseTriggeredMask;

    // Older firmware does not publish these fields; without them there is
    // nothing to reconcile against and the phone keeps its own state.
    if (reminder == null &&
        wrongBay == null &&
        emergency == null &&
        mask == null) {
      return;
    }

    if (mask != null) {
      _boxDoseTriggeredMask = mask;
    }

    final now = DateTime.now();

    // ---- Reminder / emergency alarm ----
    final boxRingingBay = (emergency == 1)
        ? 7
        : (reminder != null && reminder > 0) ? reminder : null;

    if (boxRingingBay != null) {
      final current = _activeAlarm;
      if (current != null && current.sensorNumber == boxRingingBay) {
        // Already tracking this alarm - just make sure the sound is alive.
        if (!AlarmSoundService().isRinging) {
          AlarmSoundService().startAlarm();
        }
      } else {
        // The box is ringing for a bay we are not tracking: adopt it, unless
        // we just resolved an alarm locally and this beat is stale.
        final recentlyResolved = _alarmResolvedAt != null &&
            now.difference(_alarmResolvedAt!) < _reconcileGrace;
        if (!recentlyResolved) {
          _adoptAlarm(
            DoseEvent(
              type: emergency == 1 ? 'emergency_taken' : 'reminder_started',
              sensorNumber: boxRingingBay,
              occurredAt: now,
            ),
          );
        }
      }
    } else if (_activeAlarm != null && !_activeAlarmIsLocal) {
      // The box reports no active alarm: whatever the feed says, the box
      // resolved it (taken, stopped or missed - possibly while the app was
      // closed). A phone-local scanner alarm is kept: it is the box's
      // backup and the box may never have rung for it at all.
      final recentlyRang = _alarmRangAt != null &&
          now.difference(_alarmRangAt!) < _reconcileGrace;
      if (!recentlyRang) {
        debugPrint('[repo] box reports no alarm - clearing '
            'sensor=${_activeAlarm!.sensorNumber}');
        _activeAlarm = null;
        _activeAlarmIsLocal = false;
        _alarmResolvedAt = now;
        if (_wrongBayAlertBay == null) {
          AlarmSoundService().stopAlarm();
        }
        notifyListeners();
      }
    }

    // ---- Wrong-bay warning ----
    final boxWrongBay = (wrongBay != null && wrongBay > 0) ? wrongBay : null;

    if (boxWrongBay != null) {
      if (_wrongBayAlertBay != boxWrongBay) {
        final recentlyResolved = _wrongBayResolvedAt != null &&
            now.difference(_wrongBayResolvedAt!) < _reconcileGrace;
        if (!recentlyResolved) {
          debugPrint('[repo] box reports wrong-bay sensor=$boxWrongBay');
          _wrongBayAlertBay = boxWrongBay;
          _wrongBayRangAt = now;
          _noteEventInFeed(
            DoseEvent(
              type: 'wrong_bay_taken',
              sensorNumber: boxWrongBay,
              occurredAt: now,
            ),
          );
          NotificationService().showAlarmNotification(
            id: 2,
            title: 'Medicine removed from the wrong bay',
            body: 'The dose in '
                '${MedicineSchedule.labelForBay(boxWrongBay)} was removed '
                'unexpectedly. Put the container back in the box.',
          );
          if (!AlarmSoundService().isRinging) {
            AlarmSoundService().startAlarm();
          }
          notifyListeners();
        }
      } else if (!AlarmSoundService().isRinging) {
        AlarmSoundService().startAlarm();
      }
    } else if (_wrongBayAlertBay != null) {
      final recentlyRang = _wrongBayRangAt != null &&
          now.difference(_wrongBayRangAt!) < _reconcileGrace;
      if (!recentlyRang) {
        debugPrint('[repo] box reports no wrong-bay - clearing '
            'sensor=$_wrongBayAlertBay');
        _wrongBayAlertBay = null;
        _wrongBayResolvedAt = now;
        if (_activeAlarm == null) {
          AlarmSoundService().stopAlarm();
        }
        notifyListeners();
      }
    }
  }

  /// Makes [event] the tracked alarm: rings the phone, notifies, and adds a
  /// feed row if none is fresh (an alarm the box rang while the app was
  /// closed has no Supabase row - events are only persisted by the phone).
  void _adoptAlarm(DoseEvent event) {
    debugPrint('[repo] adopting box alarm type=${event.type} '
        'sensor=${event.sensorNumber}');
    _activeAlarm = event;
    _activeAlarmIsLocal = false;
    _alarmRangAt = DateTime.now();
    _noteEventInFeed(event);
    if (!AlarmSoundService().isRinging) {
      AlarmSoundService().startAlarm();
    }
    final isEmergency = event.type == 'emergency_taken';
    NotificationService().showAlarmNotification(
      id: isEmergency ? 3 : 1,
      title: isEmergency ? 'Emergency dose taken' : 'Time for your dose',
      body: '${MedicineSchedule.labelForBay(event.sensorNumber)} is ringing. '
          '${isEmergency ? 'Please take the emergency dose.' : 'Please take your medicine.'}',
    );
    notifyListeners();
  }

  /// Adds a feed row for [event] unless an identical fresh one already
  /// exists. The row is not persisted: the box's own event (if it ever
  /// reaches the phone) is persisted through the normal path.
  void _noteEventInFeed(DoseEvent event) {
    final fresh = _events.isNotEmpty &&
        _events.first.type == event.type &&
        _events.first.sensorNumber == event.sensorNumber &&
        DateTime.now().difference(_events.first.occurredAt).abs() <
            const Duration(minutes: 5);
    if (fresh) return;
    _events.insert(0, event);
    if (_events.length > 200) {
      _events.removeRange(200, _events.length);
    }
    _lastSynced = DateTime.now();
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
    // No alarm-state restore from the feed here either - see _loadData.
    // The next status heartbeat reconciles alarm state with the box.

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
    // caregiver_stopped for that bay), so drop the local state now. The
    // resolved timestamp keeps a stale "wrong bay still ringing" status
    // beat from re-adopting it.
    _wrongBayAlertBay = null;
    _wrongBayResolvedAt = DateTime.now();

    final active = _activeAlarm;
    if (active != null) {
      _handleLocalEvent(
        DoseEvent(
          type: 'caregiver_stopped',
          sensorNumber: active.sensorNumber,
          occurredAt: DateTime.now(),
        ),
      );
    } else {
      _activeAlarm = null;
      _activeAlarmIsLocal = false;
      _alarmResolvedAt = DateTime.now();
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
    _activeAlarm = null;
    _activeAlarmIsLocal = false;
    _alarmRangAt = null;
    _alarmResolvedAt = null;
    _wrongBayRangAt = null;
    _wrongBayResolvedAt = null;
    _wrongBayAlertBay = null;
    _boxDoseTriggeredMask = null;
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
