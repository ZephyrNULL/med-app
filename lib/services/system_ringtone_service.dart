import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges to native Android ringtones via a MethodChannel in MainActivity.
class SystemRingtoneService {
  static final SystemRingtoneService _instance =
      SystemRingtoneService._internal();
  factory SystemRingtoneService() => _instance;
  SystemRingtoneService._internal();

  static const MethodChannel _channel = MethodChannel('care_cube/ringtones');

  bool get supported => !kIsWeb && Platform.isAndroid;

  static const _prefix = 'sys:';

  bool isSystemId(String id) => id.startsWith(_prefix);

  String uriOfId(String id) => id.substring(_prefix.length);

  String idOfUri(String uri) => '$_prefix$uri';

  Future<List<Map<String, String>>> listTones() async {
    if (!supported) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('listTones');
      return (raw ?? const [])
          .whereType<Map>()
          .map((m) => {
                'uri': (m['uri'] ?? '') as String,
                'name': (m['name'] ?? 'Ringtone') as String,
              })
          .toList();
    } on PlatformException catch (e) {
      debugPrint('SystemRingtoneService.listTones failed: ${e.message}');
      return const [];
    }
  }

  Future<String?> defaultAlarmUri() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('defaultAlarmUri');
    } on PlatformException catch (e) {
      debugPrint('SystemRingtoneService.defaultAlarmUri failed: ${e.message}');
      return null;
    }
  }

  /// Play a tone once (preview).
  Future<bool> playUri(String uri) async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('play', {'uri': uri}) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('SystemRingtoneService.play failed: ${e.message}');
      return false;
    }
  }

  /// Stop a one-shot preview without touching the looping alarm player.
  Future<bool> stopPreview() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('stopPreview') ?? false;
    } on PlatformException catch (e) {
      debugPrint('SystemRingtoneService.stopPreview failed: ${e.message}');
      return false;
    }
  }

  /// Loop a tone until [stopLoop] is called (alarm playback).
  Future<bool> playLoopUri(String uri) async {
    if (!supported) return false;
    try {
      return await _channel
              .invokeMethod<bool>('playLoop', {'uri': uri}) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('SystemRingtoneService.playLoop failed: ${e.message}');
      return false;
    }
  }

  Future<bool> stopLoop() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('stop') ?? false;
    } on PlatformException catch (e) {
      debugPrint('SystemRingtoneService.stop failed: ${e.message}');
      return false;
    }
  }
}