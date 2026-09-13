import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
class AlarmSoundService {
  static final AlarmSoundService _instance = AlarmSoundService._internal();
  factory AlarmSoundService() => _instance;
  AlarmSoundService._internal();

  static const _prefSound = 'alarm_sound_id';
  static const _prefVolume = 'alarm_volume';

  static const sounds = [
    AlarmSound('classic', 'Classic beeps', 'audio/alarm_classic.wav'),
    AlarmSound('siren', 'Siren', 'audio/alarm_siren.wav'),
    AlarmSound('urgent', 'Urgent pulse', 'audio/alarm_urgent.wav'),
    AlarmSound('gentle', 'Gentle chime', 'audio/alarm_gentle.wav'),
  ];

  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _preview = AudioPlayer();
  final ValueNotifier<String> _selectedNotifier = ValueNotifier('classic');
  final ValueNotifier<double> _volumeNotifier = ValueNotifier(1.0);

  bool _initialized = false;
  bool _ringing = false;

  ValueNotifier<String> get selectedSoundNotifier => _selectedNotifier;
  ValueNotifier<double> get volumeNotifier => _volumeNotifier;
  String get selectedSoundId => _selectedNotifier.value;
  double get volume => _volumeNotifier.value;
  bool get isRinging => _ringing;

  Future<void> init() async {
    if (_initialized) return;
    await _player.setPlayerMode(PlayerMode.lowLatency);
    await _preview.setPlayerMode(PlayerMode.lowLatency);

    final prefs = await SharedPreferences.getInstance();
    _selectedNotifier.value = prefs.getString(_prefSound) ?? 'classic';
    _volumeNotifier.value = (prefs.getDouble(_prefVolume) ?? 1.0).clamp(0.0, 1.0);
    await _player.setVolume(_volumeNotifier.value);

    _initialized = true;
  }

  AlarmSound? get currentSound {
    for (final s in sounds) {
      if (s.id == _selectedNotifier.value) return s;
    }
    return sounds.first;
  }

  Future<void> setSound(String id) async {
    if (!sounds.any((s) => s.id == id)) return;
    _selectedNotifier.value = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSound, id);
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
    final sound = currentSound;
    if (sound == null) return;
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.setVolume(_volumeNotifier.value);
    await _player.play(AssetSource(sound.assetPath));
  }

  Future<void> startAlarm() async {
    await init();
    if (_ringing) return;
    _ringing = true;
    await _startLoop();
  }

  Future<void> stopAlarm() async {
    _ringing = false;
    await _player.stop();
  }

  /// Play a tone once so the user can hear it before choosing.
  Future<void> preview(String id) async {
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
}