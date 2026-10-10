import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/dose_event.dart';
import '../models/medicine_schedule.dart';
import '../services/app_state.dart';
import '../services/care_cube_repository.dart';
import '../widgets/common.dart';

class HomeScreen extends StatelessWidget {
  final void Function(int tab) onNavigate;
  const HomeScreen({super.key, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = appState.repo;
    final reading = repo.latestReading;
    final schedules = repo.schedules;
    final events = repo.events;
    final nextDose = _nextDose(schedules);

    final now = DateTime.now();
    final today = DateFormat('EEEE, MMM d').format(now);

    final enabled = schedules.where((s) => s.enabled).toList();

    // Homed doses are auto-removed, so a handled dose drops out of the
    // schedule list. To keep today's plan visible (and the taken count
    // rising instead of resetting to 0/N), totals include any bay that rang
    // AND got resolved today but no longer has a schedule - i.e. was handled
    // and auto-removed. Both directions stay time-correlated, so a stray
    // `taken` from an earlier dose in the same bay cannot count a brand-new
    // schedule as handled.
    final removedSensors = _handledRemovedSensors(schedules, events, now);
    final totalDoses = enabled.length + removedSensors.length;
    final handledSensors = <int>{
      for (final s in enabled)
        if (_isResolvedSchedule(s, events, now)) s.sensorNumber,
    }..addAll(removedSensors);
    final handledToday = handledSensors.length;
    final remainingToday = totalDoses - handledToday;

    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          appState.isCaregiver ? 'Caregiver Dashboard' : 'My Medicine Box',
        ),
        actions: [
          IconButton(
            tooltip: 'Medicine schedule',
            onPressed: () => onNavigate(1),
            icon: const Icon(Icons.medication_outlined),
          ),
          IconButton(
            tooltip: 'Alerts',
            onPressed: () => onNavigate(2),
            icon: const Icon(Icons.notifications_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await repo.refreshFromServer();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Greeting + date + inspirational message
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hello, ${_firstName(appState.profile?.fullName)}',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(today,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Text(
                        _inspiration(appState.isPatient),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.primary.withValues(alpha: 0.12),
                  child: Icon(
                    appState.isCaregiver
                        ? Icons.volunteer_activism_outlined
                        : Icons.medication,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Connection status
            ConnectionStatusCard(
              connected: repo.mqttConnected,
              lastSynced: repo.lastSynced != null
                  ? DateFormat.Hm().format(repo.lastSynced!)
                  : null,
            ),
            const SizedBox(height: 16),

            // Dose progress today (remaining; drains as doses are handled)
            _DoseProgressCard(
              remainingToday: remainingToday,
              handledToday: handledToday,
              totalDoses: totalDoses,
            ),
            const SizedBox(height: 16),

            // Next dose card
            _NextDoseCard(schedule: nextDose),
            const SizedBox(height: 16),

            // Quick actions
            _QuickActions(onNavigate: onNavigate),
            const SizedBox(height: 16),

            // Environment + device info
            const SectionHeader(title: 'Box environment'),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                _freshnessLabel(repo),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: repo.isReadingStale
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final twoCols = (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: twoCols,
                      child: InfoCard(
                        icon: Icons.thermostat_outlined,
                        label: 'Temperature',
                        value: reading != null
                            ? '${reading.temperature.toStringAsFixed(1)} °C'
                            : '--',
                        accent: Colors.deepOrange,
                      ),
                    ),
                    SizedBox(
                      width: twoCols,
                      child: InfoCard(
                        icon: Icons.water_drop_outlined,
                        label: 'Humidity',
                        value: reading != null
                            ? '${reading.humidity.toStringAsFixed(1)} %'
                            : '--',
                        accent: Colors.blue,
                      ),
                    ),
                    SizedBox(
                      width: twoCols,
                      child: InfoCard(
                        icon: Icons.sensors,
                        label: 'Device',
                        value: repo.deviceId ?? 'Not paired',
                        footnote: repo.mqttConnected ? 'online' : 'offline',
                      ),
                    ),
                    SizedBox(
                      width: twoCols,
                      child: InfoCard(
                        icon: Icons.check_circle_outline,
                        label: 'Doses taken',
                        value: totalDoses == 0
                            ? '0/0'
                            : '$handledToday/$totalDoses',
                        accent: Colors.green,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),

            // Today's schedule list
            SectionHeader(
              title: 'Today\'s doses',
              trailing: Text(
                '$handledToday of $totalDoses taken',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            _TodayStatus(
              schedules: enabled,
              handledSensors: handledSensors,
              totalToday: totalDoses,
              handledToday: handledToday,
            ),
          ],
        ),
      ),
    );
  }

  String _firstName(String? full) {
    if (full == null || full.trim().isEmpty) return 'there';
    final name = full.trim().split(' ').first;
    if (name.contains('@')) return 'there';
    return name;
  }

  String _inspiration(bool isPatient) {
    if (isPatient) {
      return 'One dose at a time. Your health is worth every step.';
    }
    return 'A little support goes a long way. Thank you for caring.';
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Window around a schedule's time within which the box's reminder is
  /// considered to belong to that occurrence.
  static final _ringWindow = const Duration(minutes: 10);

  /// The reminder the box fired for this schedule's occurrence today, if
  /// any. A `taken` only counts against a schedule when it follows (near)
  /// this ring — otherwise a `taken` from an earlier dose in the same bay
  /// (e.g. a schedule that was auto-removed after being handled) would
  /// wrongly mark a brand-new schedule as already taken.
  DoseEvent? _ringFor(
      MedicineSchedule s, List<DoseEvent> events, DateTime now) {
    final target = DateTime(now.year, now.month, now.day, s.hour, s.minute);
    DoseEvent? best;
    Duration? bestDiff;
    for (final e in events) {
      if (!e.isActiveAlarm || e.sensorNumber != s.sensorNumber) continue;
      final d = e.occurredAt.toLocal();
      if (!_sameDay(d, now)) continue;
      final diff = d.difference(target).abs();
      if (diff <= _ringWindow && (bestDiff == null || diff < bestDiff)) {
        best = e;
        bestDiff = diff;
      }
    }
    return best;
  }

  bool _isResolvedSchedule(
      MedicineSchedule s, List<DoseEvent> events, DateTime now) {
    final ring = _ringFor(s, events, now);
    for (final e in events) {
      if (e.sensorNumber != s.sensorNumber) continue;
      final d = e.occurredAt.toLocal();
      if (!_sameDay(d, now)) continue;
      if (e.type == 'missed') return true;
      if (e.type == 'taken' || e.type == 'caregiver_stopped') {
        if (ring != null) {
          // The box rang for this occurrence; the resolution must follow it.
          if (!d.isBefore(ring.occurredAt.subtract(_ringGrace))) return true;
        } else {
          // No ring recorded (box offline / local scanner). Attribute the
          // resolution only if it is close to the scheduled time, so a stray
          // `taken` left over from an earlier dose in the same bay (whose
          // schedule was auto-removed) cannot mark a fresh schedule as taken.
          final late = d.difference(_targetFor(s, now));
          if (late >= -_ringGrace && late <= _noRingLate) return true;
        }
      }
    }
    return false;
  }

  DateTime _targetFor(MedicineSchedule s, DateTime now) =>
      DateTime(now.year, now.month, now.day, s.hour, s.minute);

  /// Bays that still ring (or rang) today, got resolved (taken / stopped /
  /// missed), and no longer have an enabled schedule — these are doses that
  /// were handled and auto-removed. Counting them keeps today's plan totals
  /// stable instead of collapsing to 0/0 the moment the first dose is taken.
  Set<int> _handledRemovedSensors(List<MedicineSchedule> schedules,
      List<DoseEvent> events, DateTime now) {
    final enabledBays = {
      for (final s in schedules)
        if (s.enabled) s.sensorNumber,
    };
    final removed = <int>{};
    for (final e in events) {
      if (!e.isActiveAlarm) continue;
      if (enabledBays.contains(e.sensorNumber)) continue;
      final d = e.occurredAt.toLocal();
      if (!_sameDay(d, now)) continue;
      final resolved = events.any((r) =>
          r.sensorNumber == e.sensorNumber &&
          (r.type == 'taken' ||
              r.type == 'caregiver_stopped' ||
              r.type == 'missed') &&
          _sameDay(r.occurredAt.toLocal(), now) &&
          !r.occurredAt.toLocal().isBefore(d.subtract(_ringGrace)) &&
          r.occurredAt.toLocal().difference(d) <= _noRingLate);
      if (resolved) removed.add(e.sensorNumber);
    }
    return removed;
  }

  static final _ringGrace = const Duration(minutes: 5);
  static final _noRingLate = const Duration(minutes: 90);

  MedicineSchedule? _nextDose(List<MedicineSchedule> schedules) {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    MedicineSchedule? best;
    for (final s in schedules) {
      if (!s.enabled) continue;
      final sMin = s.hour * 60 + s.minute;
      if (sMin > nowMin) {
        if (best == null || sMin < (best.hour * 60 + best.minute)) {
          best = s;
        }
      }
    }
    if (best != null) return best;
    for (final s in schedules) {
      if (!s.enabled) continue;
      final sMin = s.hour * 60 + s.minute;
      if (best == null || sMin < (best.hour * 60 + best.minute)) {
        best = s;
      }
    }
    return best;
  }

  /// Explains where the numbers above came from, so a stalled feed reads as
  /// stalled instead of looking like a stable room.
  static String _freshnessLabel(CareCubeRepository repo) {
    final age = repo.readingAge;
    if (age == null) return 'Waiting for the box to report its environment...';
    final seconds = age.inSeconds;
    final string = seconds < 5
        ? 'just now'
        : seconds < 60
            ? '${seconds}s ago'
            : seconds < 3600
                ? '${(seconds / 60).floor()}m ago'
                : '${(seconds / 3600).floor()}h ago';
    return repo.isReadingStale
        ? 'Last reading $string - the box has stopped reporting'
        : 'Updated $string';
  }
}

class _DoseProgressCard extends StatelessWidget {
  final int remainingToday;
  final int handledToday;
  final int totalDoses;
  const _DoseProgressCard({
    required this.remainingToday,
    required this.handledToday,
    required this.totalDoses,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction =
        totalDoses == 0 ? 0.0 : remainingToday / totalDoses;
    final done = handledToday >= totalDoses && totalDoses > 0;

    return Container(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                done ? Icons.emoji_events : Icons.medication,
                color: done ? Colors.amber.shade700 : scheme.secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  done
                      ? 'All doses taken. Great job!'
                      : 'Daily dose progress',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ProgressBarLabeled(
            fraction: fraction,
            label: remainingToday == 0 && totalDoses == 0
                ? 'No doses scheduled today'
                : '$remainingToday of $totalDoses doses remaining today',
            color: done ? Colors.green : scheme.secondary,
          ),
        ],
      ),
    );
  }
}

class _NextDoseCard extends StatelessWidget {
  final MedicineSchedule? schedule;
  const _NextDoseCard({required this.schedule});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: schedule == null
            ? Row(
                children: [
                  Icon(Icons.schedule,
                      size: 32, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'No medicine scheduled yet.\nAdd one from the Medicine tab.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: theme.colorScheme.primary,
                    child: const Icon(Icons.alarm,
                        color: Colors.white, size: 30),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Next dose',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Text(
                          schedule!.timeLabel,
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.inventory_2_outlined,
                                size: 16,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                schedule!.label.isNotEmpty
                                    ? '${schedule!.label} • ${schedule!.bayLabel}'
                                    : schedule!.bayLabel,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  final void Function(int tab) onNavigate;
  const _QuickActions({required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => onNavigate(1),
            icon: const Icon(Icons.medication_outlined),
            label: const Text('Add dose'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => onNavigate(2),
            icon: const Icon(Icons.history),
            label: const Text('Event history'),
          ),
        ),
      ],
    );
  }
}

class _TodayStatus extends StatelessWidget {
  final List<MedicineSchedule> schedules;
  final Set<int> handledSensors;
  final int totalToday;
  final int handledToday;
  const _TodayStatus({
    required this.schedules,
    required this.handledSensors,
    required this.totalToday,
    required this.handledToday,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (schedules.isEmpty) {
      if (totalToday > 0) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    handledToday == totalToday
                        ? 'All of today\'s doses are handled. '
                            'Add another from the Medicine tab.'
                        : 'Today\'s dose is already handled. '
                            'Add another from the Medicine tab.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No doses scheduled. Add one from the Medicine tab.',
              style: theme.textTheme.bodyMedium),
        ),
      );
    }

    final sorted = [...schedules]..sort((a, b) {
        final t = a.hour * 60 + a.minute;
        final u = b.hour * 60 + b.minute;
        return t - u;
      });

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final s in sorted)
            ListTile(
              leading: _timeBadge(context, s.hour, s.minute),
              title: Text(s.label.isNotEmpty ? s.label : s.bayLabel,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text(s.bayLabel,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              trailing: handledSensors.contains(s.sensorNumber)
                  ? _statusPill(context, 'Taken', Colors.green)
                  : _pendingPill(context, s),
            ),
        ],
      ),
    );
  }

  Widget _timeBadge(BuildContext context, int hour, int minute) {
    final scheme = Theme.of(context).colorScheme;
    final t =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    return Container(
      width: 56,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        t,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }

  Widget _statusPill(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _pendingPill(BuildContext context, MedicineSchedule s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, size: 14, color: Colors.orange),
          const SizedBox(width: 4),
          Text('Pending',
              style: const TextStyle(
                  color: Colors.orange,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}