import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/dose_event.dart';
import '../models/medicine_schedule.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../widgets/common.dart';

class AlertScreen extends StatelessWidget {
  const AlertScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = appState.repo;
    final events = repo.events;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          IconButton(
            tooltip: 'Connect a box',
            onPressed: () => _connectBox(context),
            icon: const Icon(Icons.add_link),
          ),
          IconButton(
            tooltip: 'Clear all alerts',
            onPressed: () => _confirmClearAlerts(context),
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: events.isEmpty
                ? const _EmptyAlerts()
                : _AlertFeed(events: events),
          ),
        ],
      ),
    );
  }

  /// Connect the app to a box by typing its device id.
  ///
  /// Patients pair the box into their own account; caregivers are linked by
  /// the server to the patient who already owns the box.
  Future<void> _connectBox(BuildContext context) async {
    final appState = context.read<AppState>();
    final deviceIdText = await showPairBoxDialog(context);
    if (deviceIdText == null || deviceIdText.isEmpty) return;
    if (!context.mounted) return;

    final user = SupabaseService.currentUser;
    if (user == null) return;
    if (appState.isCaregiver) {
      try {
        final box = await SupabaseService.linkCaregiverToDevice(deviceIdText);
        await appState.repo.loadForPatient(box['patient_id'] as String);
        if (context.mounted) {
          showAppToast(context, 'Connected to box $deviceIdText');
        }
      } catch (e) {
        if (context.mounted) {
          showAppToast(context, 'Connection failed: $e', destructive: true);
        }
      }
      return;
    }
    try {
      await SupabaseService.pairBox(
        patientId: user.id,
        deviceId: deviceIdText,
      );
      await appState.repo.loadForPatient(user.id);
      if (context.mounted) {
        showAppToast(context, 'Connected to box $deviceIdText');
      }
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, 'Connection failed: $e', destructive: true);
      }
    }
  }

  void _confirmClearAlerts(BuildContext context) {
    final repo = context.read<AppState>().repo;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all alerts?'),
        content: const Text(
          'Clears this feed on your device. History stays safe in the cloud. '
          'A ringing alarm keeps ringing — take the dose or ask your '
          'caregiver to stop it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              repo.clearAlerts();
              Navigator.pop(dialogContext);
            },
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }
}

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none,
                size: 72, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No alerts yet',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Events from your box will appear here.\nThis includes reminders started, doses taken, missed doses and emergency doses taken from the emergency bay (Day 7).',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                _LegendChip(
                    icon: Icons.alarm,
                    label: 'Reminder',
                    color: Colors.orange),
                _LegendChip(
                    icon: Icons.check_circle,
                    label: 'Taken',
                    color: Colors.green),
                _LegendChip(
                    icon: Icons.emergency_outlined,
                    label: 'Emergency',
                    color: Colors.red),
                _LegendChip(
                    icon: Icons.stop_circle_outlined,
                    label: 'Stopped',
                    color: Colors.blue),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _LegendChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

enum _AlertFilter { all, reminders, taken, emergency }

class _AlertFeed extends StatefulWidget {
  final List<DoseEvent> events;
  const _AlertFeed({required this.events});

  @override
  State<_AlertFeed> createState() => _AlertFeedState();
}

class _AlertFeedState extends State<_AlertFeed> {
  _AlertFilter _filter = _AlertFilter.all;

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered();

    final taken = widget.events.where((e) => e.type == 'taken').length;
    final reminders =
        widget.events.where((e) => e.type == 'reminder_started').length;
    final emergency = widget.events
        .where((e) =>
            e.type == 'emergency_taken' ||
            e.type == 'emergency_returned' ||
            e.type == 'missed')
        .length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              _StatTile(
                  icon: Icons.all_inbox,
                  label: 'Total',
                  value: widget.events.length,
                  color: Colors.grey.shade700),
              _StatTile(
                  icon: Icons.check_circle,
                  label: 'Taken',
                  value: taken,
                  color: Colors.green),
              _StatTile(
                  icon: Icons.alarm,
                  label: 'Reminders',
                  value: reminders,
                  color: Colors.orange),
              _StatTile(
                  icon: Icons.emergency,
                  label: 'Emergency',
                  value: emergency,
                  color: Colors.red),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _AlertFilter.values)
                ChoiceChip(
                  label: Text(f.name == 'all'
                      ? 'All'
                      : f.name[0].toUpperCase() + f.name.substring(1)),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text('No events match this filter.',
                      style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  itemCount: filtered.length,
                  itemBuilder: (context, i) =>
                      _EventTile(event: filtered[i]),
                ),
        ),
      ],
    );
  }

  List<DoseEvent> _filtered() {
    switch (_filter) {
      case _AlertFilter.all:
        return widget.events;
      case _AlertFilter.reminders:
        return widget.events
            .where((e) =>
                e.type == 'reminder_started' || e.type == 'missed')
            .toList();
      case _AlertFilter.taken:
        return widget.events
            .where((e) => e.type == 'taken' || e.type == 'caregiver_stopped')
            .toList();
      case _AlertFilter.emergency:
        return widget.events
            .where((e) =>
                e.type == 'emergency_taken' ||
                e.type == 'emergency_returned' ||
                e.type == 'missed')
            .toList();
    }
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final Color color;
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 4),
            Text('$value',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Banner shown when a reminder/emergency alarm is unacknowledged.
/// Caregiver gets a "Stop Alarm" button; patient does not.
class _EventTile extends StatelessWidget {
  final DoseEvent event;
  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCaregiverStop = event.type == 'caregiver_stopped';
    final isEmergency = event.type == 'emergency_taken';
    final isEmergencyReturned = event.type == 'emergency_returned';
    final isTaken = event.type == 'taken';
    final isReminder = event.type == 'reminder_started';
    final isMissed = event.type == 'missed';
    final isWrongBay = event.type == 'wrong_bay_taken';

    IconData icon;
    Color color;
    if (isEmergency) {
      icon = Icons.emergency_outlined;
      color = Colors.red;
    } else if (isEmergencyReturned) {
      icon = Icons.playlist_add_check_circle;
      color = Colors.redAccent;
    } else if (isMissed) {
      icon = Icons.error_outline;
      color = Colors.redAccent;
    } else if (isWrongBay) {
      icon = Icons.warning_amber_rounded;
      color = Colors.deepOrange;
    } else if (isReminder) {
      icon = Icons.alarm;
      color = Colors.orange;
    } else if (isTaken) {
      icon = Icons.check_circle;
      color = Colors.green;
    } else if (isCaregiverStop) {
      icon = Icons.stop_circle_outlined;
      color = Colors.blue;
    } else {
      icon = Icons.info_outline;
      color = theme.colorScheme.onSurfaceVariant;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: color, size: 20),
          ),
          title: Text(
            event.friendlyType,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
              '${MedicineSchedule.labelForBay(event.sensorNumber)} • ${DateFormat('MMM d, HH:mm').format(event.occurredAt)}'),
          trailing: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }
}