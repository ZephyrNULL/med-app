import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/dose_event.dart';
import '../models/medicine_schedule.dart';
import '../services/app_state.dart';
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
    final takenSensors = _takenSensorsToday(events, now);
    final takenToday =
        enabled.where((s) => takenSensors.contains(s.sensorNumber)).length;

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

            // Dose progress today
            _DoseProgressCard(
              takenToday: takenToday,
              totalDoses: enabled.length,
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
            const SizedBox(height: 8),
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
                        value: enabled.isEmpty
                            ? '0/0'
                            : '$takenToday/${enabled.length}',
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
                '$takenToday of ${enabled.length} taken',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            _TodayStatus(schedules: enabled, takenSensors: takenSensors),
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

  Set<int> _takenSensorsToday(List<DoseEvent> events, DateTime now) {
    final sensors = <int>{};
    for (final e in events) {
      if (e.type != 'taken') continue;
      final d = e.occurredAt.toLocal();
      if (d.year == now.year && d.month == now.month && d.day == now.day) {
        sensors.add(e.sensorNumber);
      }
    }
    return sensors;
  }

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
}

class _DoseProgressCard extends StatelessWidget {
  final int takenToday;
  final int totalDoses;
  const _DoseProgressCard({
    required this.takenToday,
    required this.totalDoses,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = totalDoses == 0 ? 0.0 : takenToday / totalDoses;
    final done = takenToday >= totalDoses && totalDoses > 0;

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
            label: '$takenToday of $totalDoses doses taken today',
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
                                    ? '${schedule!.label} • Day ${schedule!.sensorNumber}'
                                    : 'Day ${schedule!.sensorNumber}',
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
  final Set<int> takenSensors;
  const _TodayStatus({
    required this.schedules,
    required this.takenSensors,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (schedules.isEmpty) {
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
              title: Text(s.label.isNotEmpty ? s.label : 'Day ${s.sensorNumber}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text('Day ${s.sensorNumber}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              trailing: takenSensors.contains(s.sensorNumber)
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