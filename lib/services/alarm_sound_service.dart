import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_ringtone_service.dart';

/// A user-selectable alarm tone bundled with the app.
class AlarmSound {
  final String id;
  final String name;
  final String assetPath;
  const AlarmSound(this.id, this.name, this.assetPath);
}

/// Plays the phone-side alarm when the box reports a reminder/emergency,
/// and persists the chosen tone + volume. The ESP32 buzzer rings at the box;
/// this service rings the phone so the patient hears it too.
///
/// Sounds can be a bundled asset or a user-selected Android system
/// ringtone/alarm tone (id prefixed with `sys:`).
class AlarmSoundService {
  static final AlarmSoundService _instance = AlarmSoundService._internal();
  factory AlarmSoundService() => _instance;
  AlarmSoundService._internal();

  static const _prefSound = 'alarm_sound_id';
  static const _prefSoundName = 'alarm_sound_name';
  static const _prefVolume = 'alarm_volume';

  static const sounds = [
    AlarmSound('classic', 'Classic beeps', 'audio/alarm_classic.wav'),
    AlarmSound('siren', 'Siren', 'audio/alarm_siren.wav'),
    AlarmSound('urgent', 'Urgent pulse', 'audio/alarm_urgent.wav'),
    AlarmSound('gentle', 'Gentle chime', 'audio/alarm_gentle.wav'),
  ];

  /// How often the ringing alarm is checked for having gone silent.
  static const _watchdogInterval = Duration(seconds: 4);

  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _preview = AudioPlayer();
  final ValueNotifier<String> _selectedNotifier = ValueNotifier('classic');
  final ValueNotifier<double> _volumeNotifier = ValueNotifier(1.0);

  bool _initialized = false;
  bool _ringing = false;
  String _selectedName = 'Classic beeps';

  /// Guards against re-entrant playback. `_startLoop()` stops the player
  /// before (re)starting it, and that stop emits a stopped-state callback
  /// which used to re-enter `_reviveIfSilent()` -> `_startLoop()` in a tight
  /// loop, so the tone was stopped/restarted dozens of times a second and
  /// was never actually audible. While these are set, state callbacks and
  /// revive attempts are ignored.
  bool _startingLoop = false;
  bool _reviving = false;

  Timer? _watchdog;

  /// Last time the native player reported playback progress. A looping alarm
  /// that is really playing keeps advancing its position; one that has been
  /// silently paused stops, which is how the watchdog notices.
  DateTime? _lastProgressAt;

  /// Android plays whatever we declare through this context. The plugin
  /// defaults to USAGE_MEDIA / music content, which is muted by the ringer
  /// silent switch, suppressed by Do Not Disturb, and follows the media
  /// volume slider (often at zero). Declaring the alarm stream is the
  /// difference between an alarm that is audible and one that is not.
  ///
  /// `audioMode` must stay NORMAL. `MODE_RINGTONE` routes playback through
  /// the ringer and makes the tone follow the ring volume / silent switch,
  /// so an alarm silently disappears when the phone is on vibrate. The
  /// `USAGE_ALARM` attribute is what actually puts it on the alarm stream.
  AudioContext get _alarmContext => AudioContext(
        android: AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          contentType: AndroidContentType.sonification,
          audioMode: AndroidAudioMode.normal,
          audioFocus: AndroidAudioFocus.gain,
          stayAwake: true,
        ),
      );

  ValueNotifier<String> get selectedSoundNotifier => _selectedNotifier;
  ValueNotifier<double> get volumeNotifier => _volumeNotifier;
  String get selectedSoundId => _selectedNotifier.value;
  double get volume => _volumeNotifier.value;
  bool get isRinging => _ringing;

  /// Display name of the currently selected tone (bundled or system).
  String get selectedSoundName => _selectedName;

  bool get isSystemTone =>
      SystemRingtoneService().isSystemId(_selectedNotifier.value);

  Future<void> init() async {
    if (_initialized) return;

    // Bundled tones use the media player so the alarm audio attributes are
    // honoured; SoundPool ignores most of them.
    await _player.setPlayerMode(PlayerMode.mediaPlayer);
    await _player.setAudioContext(_alarmContext);
    await _preview.setPlayerMode(PlayerMode.lowLatency);

    _player.onPositionChanged.listen((_) => _lastProgressAt = DateTime.now());
    _player.onPlayerStateChanged.listen((s) {
      // Ignore the state changes we cause ourselves while (re)starting the
      // loop; only an unexpected pause/stop while ringing should trigger a
      // revive. Otherwise stopping the player inside _startLoop re-enters
      // revive forever.
      if (_startingLoop || _reviving) return;
      // The Android plugin pauses on audio-focus loss; if that leaves the
      // alarm audibly dead, bring it straight back.
      if (_ringing && s != PlayerState.playing) {
        unawaited(_reviveIfSilent());
      }
    });

    final prefs = await SharedPreferences.getInstance();
    _selectedNotifier.value = prefs.getString(_prefSound) ?? 'classic';
    _selectedName = prefs.getString(_prefSoundName) ?? 'Classic beeps';
    _volumeNotifier.value = (prefs.getDouble(_prefVolume) ?? 1.0).clamp(0.0, 1.0);
    await _player.setVolume(_volumeNotifier.value);

    // Prime the native player once at startup. On Android the very first
    // play() on a freshly created player can be dropped while the platform
    // player/audio context is still being set up, which made the first
    // alarm of a session silent until the user visited the alarm-sound
    // picker (whose preview effectively warmed the player up). Doing it
    // here - silently - makes the first real alarm sound reliably.
    await _warmUp();

    _initialized = true;
  }

  /// Plays the selected tone once at zero volume to force the native player
  /// and audio context to be created, then restores the real volume.
  Future<void> _warmUp() async {
    final sound = currentSound ?? sounds.first;
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setVolume(0);
      await _player.play(AssetSource(sound.assetPath));
      await _player.stop();
    } catch (e) {
      debugPrint('Alarm warm-up failed: $e');
    } finally {
      await _player.setVolume(_volumeNotifier.value);
    }
  }

  AlarmSound? get currentSound {
    for (final s in sounds) {
      if (s.id == _selectedNotifier.value) return s;
    }
    return null;
  }

  String? get currentSystemUri {
    final id = _selectedNotifier.value;
    final sys = SystemRingtoneService();
    return sys.isSystemId(id) ? sys.uriOfId(id) : null;
  }

  /// Select a tone by id (a bundled id like 'classic' or a `sys:` uri).
  Future<void> setSound(String id, {String? name}) async {
    final sys = SystemRingtoneService();
    final isBundled = sounds.any((s) => s.id == id);
    if (!isBundled && !sys.isSystemId(id)) return;

    _selectedNotifier.value = id;
    if (name != null) _selectedName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSound, id);
    await prefs.setString(_prefSoundName, _selectedName);
    if (_ringing) {
      await _startLoop();
    }
  }

  Future<void> setVolume(double v) async {
    final clamped = v.clamp(0.0, 1.0);
    _volumeNotifier.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefVolume, clamped);
    await _player.setVolume(clamped);
  }

  Future<void> _startLoop() async {
    if (_startingLoop) return;
    _startingLoop = true;
    try {
      _lastProgressAt = null;
      try {
        await _player.stop();
      } catch (e) {
        debugPrint('Failed to reset alarm player: $e');
      }

      final sys = SystemRingtoneService();
      final systemUri = currentSystemUri;
      if (systemUri != null && sys.supported) {
        final started = await sys.playLoopUri(systemUri);
        if (started) return;
        // A system tone that will not play (deleted file, denied URI) must
        // not leave the alarm silent - fall back to a bundled tone.
        debugPrint('System ringtone failed to start; using bundled tone');
        await sys.stopLoop();
      }

      final sound = currentSound ?? sounds.first;
      try {
        await _player.setAudioContext(_alarmContext);
        await _player.setReleaseMode(ReleaseMode.loop);
        await _player.setVolume(_volumeNotifier.value);
        await _player.play(AssetSource(sound.assetPath));
        _lastProgressAt = DateTime.now();
      } catch (e) {
        debugPrint('Failed to start alarm tone: $e');
      }
    } finally {
      _startingLoop = false;
    }
  }

  Future<void> startAlarm() async {
    await init();
    if (_ringing) {
      // Already flagged as ringing: it may be a stuck flag from a focus
      // loss that silently paused playback. Make sure it really sounds.
      _startWatchdog();
      unawaited(_reviveIfSilent());
      return;
    }
    _ringing = true;
    await _startLoop();
    _startWatchdog();
  }

  Future<void> stopAlarm() async {
    _ringing = false;
    _stopWatchdog();
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('Failed to stop alarm player: $e');
    }
    await SystemRingtoneService().stopLoop();
  }

  /// Play a tone once so the user can hear it before choosing.
  Future<void> preview(String id) async {
    final sys = SystemRingtoneService();
    if (sys.isSystemId(id)) {
      await _preview.stop();
      await sys.playUri(sys.uriOfId(id));
      return;
    }
    var sound = sounds.first;
    for (final s in sounds) {
      if (s.id == id) {
        sound = s;
        break;
      }
    }
    await _preview.stop();
    await _preview.setReleaseMode(ReleaseMode.release);
    await _preview.play(AssetSource(sound.assetPath));
  }

  /// Stop only the sound-picker preview. Deliberately does NOT touch the
  /// alive alarm player: choosing a tone must never silence a ringing alarm.
  Future<void> stopPreview() async {
    try {
      await _preview.stop();
    } catch (e) {
      debugPrint('Failed to stop preview: $e');
    }
    await SystemRingtoneService().stopPreview();
  }

  // ---- Watchdog ------------------------------------------------------

  /// The Android plugin pauses the player when audio focus is lost and, on
  /// permanent loss, stops playing for good. The Dart `_ringing` flag used
  /// to stay true through that, so `startAlarm()` returned early forever
  /// and the alarm never sounded again until the app was restarted. This
  /// re-arms the tone while an alarm is supposed to be active.
  void _startWatchdog() {
    _watchdog ??= Timer.periodic(_watchdogInterval, (_) => _reviveIfSilent());
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  Future<void> _reviveIfSilent() async {
    if (!_ringing || _reviving || _startingLoop) return;

    // Healthy: the player says it is playing and progress is advancing.
    final stalled = _lastProgressAt == null ||
        DateTime.now().difference(_lastProgressAt!) > _watchdogInterval * 2;
    if (_player.state == PlayerState.playing && !stalled) return;

    _reviving = true;
    try {
      // Only revive the bundled player when a system tone is not the
      // selected one; the system ringtone is driven natively.
      if (currentSystemUri != null) {
        final sys = SystemRingtoneService();
        if (sys.supported) {
          await sys.playLoopUri(currentSystemUri!);
          return;
        }
      }

      debugPrint('Alarm was silent while active - restarting tone');
      await _startLoop();
    } catch (e) {
      debugPrint('Alarm watchdog check failed: $e');
    } finally {
      _reviving = false;
    }
  }
}