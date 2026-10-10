/// A schedule entry.
///
/// Mirrors the ESP32 firmware's slot model: 6 slots, each mapped to a
/// physical sensor bay 1-6. Bay 7 is reserved for emergency and is NOT
/// schedulable.
///
/// The box stores only TWO days, morning (M), afternoon (A) and night (N),
/// so the six schedulable bays are Day 1M, Day 1A, Day 1N, Day 2M,
/// Day 2A, Day 2N.
class MedicineSchedule {
  final String? id;
  final int slot; // 0-5 on firmware, index into the 6-slot arrays
  final int sensorNumber; // 1-6 physical bay
  final int hour;
  final int minute;
  final bool enabled;
  final String label;

  MedicineSchedule({
    this.id,
    required this.slot,
    required this.sensorNumber,
    required this.hour,
    required this.minute,
    this.enabled = true,
    this.label = '',
  });

  /// Human-readable name for a physical bay (1-based).
  ///
  /// Bays 1-6 are the two stored days split into morning (M), afternoon (A)
  /// and night (N): 1 = Day 1M, 2 = Day 1A, 3 = Day 1N, 4 = Day 2M,
  /// 5 = Day 2A, 6 = Day 2N. Bay 7 is the emergency bay. Anything else
  /// falls back to "Bay N" so a stray value never renders as a bogus day.
  static const _periods = ['M', 'A', 'N'];

  static String labelForBay(int sensorNumber) {
    if (sensorNumber >= 1 && sensorNumber <= 6) {
      final day = ((sensorNumber - 1) ~/ 3) + 1;
      final period = _periods[(sensorNumber - 1) % 3];
      return 'Day $day$period';
    }
    if (sensorNumber == 7) return 'Day 7 (emergency)';
    return 'Bay $sensorNumber';
  }

  /// Name of the compartment this schedule lives in, e.g. "Day 2M".
  String get bayLabel => labelForBay(sensorNumber);

  factory MedicineSchedule.fromMap(Map<String, dynamic> map) {
    return MedicineSchedule(
      id: map['id'] as String?,
      slot: (map['slot'] ?? 0) as int,
      sensorNumber: (map['sensor_number'] ?? 1) as int,
      hour: (map['hour'] ?? 12) as int,
      minute: (map['minute'] ?? 0) as int,
      enabled: (map['enabled'] ?? true) as bool,
      label: (map['label'] ?? '') as String,
    );
  }

  /// Serialize for the ESP32 firmware's `schedule/set` topic.
  ///
  /// The firmware's `handleScheduleUpdate()` expects a JSON array:
  /// [{"slot":0,"sensor_number":2,"hour":8,"minute":0,"enabled":true}, ...]
  Map<String, dynamic> toFirmwareJson() {
    return {
      'slot': slot,
      'sensor_number': sensorNumber,
      'hour': hour,
      'minute': minute,
      'enabled': enabled,
    };
  }

  /// Serialize for Supabase `schedules` table.
  Map<String, dynamic> toDbMap(String boxId) {
    return {
      'box_id': boxId,
      'slot': slot,
      'sensor_number': sensorNumber,
      'hour': hour,
      'minute': minute,
      'enabled': enabled,
      'label': label,
    };
  }

  String get timeLabel {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
