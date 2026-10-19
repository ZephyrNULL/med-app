import 'package:flutter_test/flutter_test.dart';

import 'package:care_cube/models/dose_event.dart';
import 'package:care_cube/models/medicine_schedule.dart';

void main() {
  group('MedicineSchedule -> firmware JSON', () {
    test('serializes to the exact shape the ESP32 expects', () {
      final s = MedicineSchedule(
        id: 'abc',
        slot: 2,
        sensorNumber: 4,
        hour: 8,
        minute: 30,
        enabled: true,
        label: 'Morning dose',
      );

      final json = s.toFirmwareJson();
      expect(json['slot'], 2);
      expect(json['sensor_number'], 4);
      expect(json['hour'], 8);
      expect(json['minute'], 30);
      expect(json['enabled'], true);
    });

    test('enabled flag serializes as bool', () {
      final off = MedicineSchedule(
        slot: 0,
        sensorNumber: 1,
        hour: 12,
        minute: 0,
        enabled: false,
      );
      expect(off.toFirmwareJson()['enabled'], false);
    });

    test('bay 7 is labeled as the emergency bay and is not schedulable', () {
      expect(MedicineSchedule.labelForBay(7), 'Day 7 (emergency)');
      expect(MedicineSchedule.labelForBay(3), 'Day 1N');
    });

    test('labels all 7 sensor bays correctly', () {
      const expected = {
        1: 'Day 1M',
        2: 'Day 1A',
        3: 'Day 1N',
        4: 'Day 2M',
        5: 'Day 2A',
        6: 'Day 2N',
        7: 'Day 7 (emergency)',
      };
      expected.forEach((bay, label) {
        expect(MedicineSchedule.labelForBay(bay), label, reason: 'bay $bay');
      });
    });
  });

  group('MedicineSchedule -> DB map', () {
    test('includes box_id and label', () {
      final s = MedicineSchedule(
        id: 'id-1',
        slot: 1,
        sensorNumber: 2,
        hour: 10,
        minute: 0,
        label: 'Lunch',
      );
      final map = s.toDbMap('box-123');
      expect(map['box_id'], 'box-123');
      expect(map['label'], 'Lunch');
      expect(map['sensor_number'], 2);
    });
  });

  group('DoseEvent emergency types', () {
    test('emergency_taken is active and labeled Emergency Taken', () {
      final e = DoseEvent(
        type: 'emergency_taken',
        sensorNumber: 7,
        occurredAt: DateTime.now(),
      );
      expect(e.isActiveAlarm, isTrue);
      expect(e.friendlyType, 'Emergency Taken');
    });

    test('emergency_returned resolves the alarm', () {
      final e = DoseEvent(
        type: 'emergency_returned',
        sensorNumber: 7,
        occurredAt: DateTime.now(),
      );
      expect(e.isActiveAlarm, isFalse);
      expect(e.friendlyType, 'Emergency container returned');
    });

    test('parses a live emergency_returned message from MQTT', () {
      final e = DoseEvent.fromEventJson({
        'device_id': 'carecube-001',
        'type': 'emergency_returned',
        'sensor_number': 7,
        'timestamp': 1800000000,
      });
      expect(e.sensorNumber, 7);
      expect(e.isActiveAlarm, isFalse);
      expect(e.occurredAt, DateTime.fromMillisecondsSinceEpoch(1800000000000));
    });

    test('a taken event for every bay 1-7 parses with its sensor number', () {
      for (var bay = 1; bay <= 7; bay++) {
        final e = DoseEvent.fromEventJson({
          'device_id': 'carecube-001',
          'type': bay == 7 ? 'emergency_returned' : 'taken',
          'sensor_number': bay,
          'timestamp': 1800000000,
        });
        expect(e.sensorNumber, bay, reason: 'bay $bay');
        expect(e.isActiveAlarm, isFalse, reason: 'bay $bay');
      }
    });

    test('wrong_bay_taken is informational, not an alarm', () {
      final e = DoseEvent.fromEventJson({
        'device_id': 'carecube-001',
        'type': 'wrong_bay_taken',
        'sensor_number': 3,
        'timestamp': 1800000000,
      });
      expect(e.sensorNumber, 3);
      expect(e.isActiveAlarm, isFalse);
      expect(e.isInformational, isTrue);
      expect(e.friendlyType, 'Medicine removed from wrong bay');
    });
  });
}