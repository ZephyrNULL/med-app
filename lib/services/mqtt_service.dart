import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../config/app_config.dart';
import '../models/box_reading.dart';
import '../models/dose_event.dart';
import '../models/medicine_schedule.dart';

/// MQTT service that implements the ESP32 firmware's broker contract.
///
/// Topic contract (from CareCube_ESP32_Firmware_v2.ino):
///   carecube/{device_id}/schedule/set  App -> ESP32  JSON array of slots
///   carecube/{device_id}/time/set      App -> ESP32  {tz_offset_minutes}
///   carecube/{device_id}/status        ESP32 -> App  {temperature,humidity,timestamp}
///   carecube/{device_id}/event         ESP32 -> App  {type,sensor_number,timestamp}
///   carecube/{device_id}/alarm/stop    App -> ESP32  (caregiver only)
class MqttService {
  static final MqttService _instance = MqttService._internal();
  factory MqttService() => _instance;
  MqttService._internal();

  MqttServerClient? _client;
  String? _deviceId;
  bool _isConnected = false;
  DateTime? _lastStatusAt;
  StreamSubscription? _messageSubscription;

  final _statusController = StreamController<BoxReading>.broadcast();
  Stream<BoxReading> get statusStream => _statusController.stream;

  final _eventController = StreamController<DoseEvent>.broadcast();
  Stream<DoseEvent> get eventStream => _eventController.stream;

  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  bool get isConnected => _isConnected;
  DateTime? get lastStatusAt => _lastStatusAt;
  String? get deviceId => _deviceId;

  String get _topicScheduleSet => 'carecube/$_deviceId/schedule/set';
  String get _topicStatus => 'carecube/$_deviceId/status';
  String get _topicEvent => 'carecube/$_deviceId/event';
  String get _topicAlarmStop => 'carecube/$_deviceId/alarm/stop';
  String get _topicTimeSet => 'carecube/$_deviceId/time/set';

  Future<bool> connect(String deviceId) async {
    if (isConnected && _deviceId == deviceId) return true;

    await disconnect();

    _deviceId = deviceId;
    final clientId =
        'care_cube_app_${DateTime.now().millisecondsSinceEpoch}';

    final client = MqttServerClient(
      AppConfig.mqttBrokerHost,
      clientId,
    );
    client.port = AppConfig.mqttBrokerPort;
    client.secure = true;
    client.setProtocolV311();
    client.keepAlivePeriod = 20;
    client.connectTimeoutPeriod = 5000;
    client.logging(on: false);
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    client.onDisconnected = onDisconnected;
    client.onConnected = onConnected;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();

    if (AppConfig.mqttUsername.isNotEmpty) {
      connMess.authenticateAs(AppConfig.mqttUsername, AppConfig.mqttPassword);
    }
    client.connectionMessage = connMess;

    try {
      await client.connect();
    } catch (e) {
      // ignore: avoid_print
      print('MQTT connect error: $e');
      return false;
    }

    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      _isConnected = true;
      _client = client;
      _connectionController.add(true);
      _setupSubscriptions();
      publishTimeZone();
      return true;
    }

    return false;
  }

  void _setupSubscriptions() {
    final client = _client;
    if (client == null || _deviceId == null) return;

    _messageSubscription?.cancel();

    // We only care about status + event topics from the ESP32.
    client.subscribe(_topicStatus, MqttQos.atLeastOnce);
    client.subscribe(_topicEvent, MqttQos.atLeastOnce);

    _messageSubscription = client.updates?.listen(_onMessage);
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage?>>? messages) {
    if (messages == null) return;

    for (final received in messages) {
      final payload = received.payload as MqttPublishMessage;
      final topic = received.topic;
      final text =
          MqttPublishPayload.bytesToStringAsString(payload.payload.message);

      // ignore: avoid_print
      print('MQTT <- [$topic] $text');

      Map<String, dynamic>? json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      if (topic == _topicStatus) {
        final reading = BoxReading.fromStatusJson(json);
        _lastStatusAt = DateTime.now();
        _statusController.add(reading);
      } else if (topic == _topicEvent) {
        final event = DoseEvent.fromEventJson(json);
        _eventController.add(event);
      }
    }
  }

  /// Send the full schedule to the ESP32 (idempotent replace).
  ///
  /// Matches the firmware's `handleScheduleUpdate()` which expects a JSON
  /// array of `{"slot","sensor_number","hour","minute","enabled"}`.
  void publishSchedule(List<MedicineSchedule> schedules) {
    if (!_isConnected || _deviceId == null) return;

    // Ensure every slot 0-5 is present; missing slots are disabled.
    final bySlot = <int, MedicineSchedule>{};
    for (final s in schedules) {
      bySlot[s.slot] = s;
    }
    final payload = [
      for (var slot = 0; slot < 6; slot++)
        (bySlot[slot]?.toFirmwareJson() ??
            {
              'slot': slot,
              'sensor_number': slot + 1,
              'hour': 0,
              'minute': 0,
              'enabled': false,
            }),
    ];

    _publish(_topicScheduleSet, jsonEncode(payload));
  }

  /// Tell the box which UTC offset this phone is on.
  ///
  /// Dose times are entered and evaluated as local wall-clock time on both
  /// sides, so the box has to know the phone's offset or every reminder fires
  /// shifted (it used to be hard-coded to UTC+05:30). Re-published on every
  /// connection, resume and schedule push so a box that booted offline still
  /// picks it up, and so travel/DST changes reach it too.
  void publishTimeZone() {
    if (!_isConnected || _deviceId == null) return;
    _publish(
      _topicTimeSet,
      jsonEncode({
        'tz_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
      }),
    );
  }

  /// Caregiver-only remote alarm stop.
  void stopAlarm() {
    if (!_isConnected || _deviceId == null) return;
    _publish(_topicAlarmStop, '{}');
  }

  void publishDoseEvent(DoseEvent event) {
    if (!_isConnected || _deviceId == null) return;
    _publish(
      _topicEvent,
      jsonEncode({
        'device_id': _deviceId,
        'type': event.type,
        'sensor_number': event.sensorNumber,
        'timestamp': event.occurredAt.millisecondsSinceEpoch ~/ 1000,
      }),
    );
  }

  void _publish(String topic, String payload) {
    final client = _client;
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }

    final builder = MqttClientPayloadBuilder()..addString(payload);
    client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
    // ignore: avoid_print
    print('MQTT -> [$topic] $payload');
  }

  void onConnected() {
    // ignore: avoid_print
    print('MQTT connected');
    _isConnected = true;
    _connectionController.add(true);
    publishTimeZone();
  }

  void onDisconnected() {
    // ignore: avoid_print
    print('MQTT disconnected');
    _isConnected = false;
    _connectionController.add(false);
  }

  Future<void> disconnect() async {
    final client = _client;
    if (client != null) {
      client.disconnect();
    }
    _client = null;
    _messageSubscription?.cancel();
    _messageSubscription = null;
    if (_isConnected) {
      _isConnected = false;
      _connectionController.add(false);
    }
  }

  void dispose() {
    _statusController.close();
    _eventController.close();
    _connectionController.close();
  }
}
