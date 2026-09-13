import 'package:flutter_test/flutter_test.dart';

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
  });

  group('MedicineSchedule -> DB map', () {
    test('includes box_id and label', () {
      final s = MedicineSchedule(
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
}
