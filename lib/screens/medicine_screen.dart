import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/medicine_schedule.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../widgets/common.dart';

class MedicineScreen extends StatelessWidget {
  const MedicineScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppState>().repo;
    final schedules = repo.schedules;
    final enabledCount = schedules.where((s) => s.enabled).length;
    final scheme = Theme.of(context).colorScheme;
    // Schedules are pushed from the box; while it is not reporting, hide the
    // persisted plan rather than presenting it as current.
    final online = repo.boxOnline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Medicine'),
        actions: [
          if (online)
            IconButton(
              tooltip: 'Add dose',
              onPressed: () => _openEditor(context, null),
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: !online
          ? const BoxOfflineCard(
              message: 'Your Care Cube is offline, so your dose schedule is '
                  'hidden until it starts reporting again.',
            )
          : schedules.isEmpty
              ? _EmptyState(onAdd: () => _openEditor(context, null))
              : RefreshIndicator(
                  onRefresh: repo.refreshFromServer,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _SummaryCard(
                        totalDoses: schedules.length,
                        enabledDoses: enabledCount,
                      ),
                      const SizedBox(height: 16),
                      SectionHeader(
                        title: 'Dose schedule',
                        trailing: Text(
                          '$enabledCount active',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final s in schedules)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ScheduleTile(
                            schedule: s,
                            onTap: () => _openEditor(context, s),
                            onDelete: () async {
                              final id = s.id;
                              if (id == null) return;
                              try {
                                await repo.deleteSchedule(id);
                              } catch (e) {
                                if (context.mounted) {
                                  showAppToast(context,
                                      'Could not delete dose: $e',
                                      destructive: true);
                                }
                              }
                            },
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'The box stores 2 days (morning, afternoon and night). '
                        'Bay 7 is reserved '
                        'for emergency doses and cannot be scheduled.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
    );
  }

  void _openEditor(BuildContext context, MedicineSchedule? existing) {
    if (existing == null && context.read<AppState>().repo.boxId == null) {
      _promptPairBox(context);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ScheduleEditor(schedule: existing),
    );
  }

  /// Lets a patient re-pair their box after pairing data was lost
  /// (e.g. DB reset) so they can add doses again.
  Future<void> _promptPairBox(BuildContext context) async {
    final appState = context.read<AppState>();
    final deviceIdText = await showPairBoxDialog(context);
    if (deviceIdText == null || deviceIdText.isEmpty) return;
    if (!context.mounted) return;

    final user = SupabaseService.currentUser;
    if (user == null) return;
    try {
      await SupabaseService.pairBox(
        patientId: user.id,
        deviceId: deviceIdText,
      );
      await appState.repo.loadForPatient(user.id);
      if (context.mounted) showAppToast(context, 'Box paired!');
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, 'Pairing failed: $e', destructive: true);
      }
    }
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.medication_outlined,
                size: 72, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No doses scheduled yet',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Add your first medicine dose so the Care Cube knows when to remind you. The box stores 2 days across 6 compartments (Day 1M / 1A / 1N, Day 2M / 2A / 2N).\n\nEach schedule appears on the LCD display and triggers the reminder LED, buzzer and an alert in this app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add Dose'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int totalDoses;
  final int enabledDoses;
  const _SummaryCard({
    required this.totalDoses,
    required this.enabledDoses,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.medication, color: scheme.primary, size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Medication plan',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '$totalDoses scheduled • $enabledDoses active • '
                  '2 days (morning · afternoon · night)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ScheduleEditor extends StatefulWidget {
  final MedicineSchedule? schedule;
  const ScheduleEditor({super.key, this.schedule});

  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  late int _slot;
  late int _sensor;
  late int _hour;
  late int _minute;
  late bool _enabled;
  final _label = TextEditingController();
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);

  @override
  void initState() {
    super.initState();
    final s = widget.schedule;
    _slot = s?.slot ?? _nextFreeSlot();
    _sensor = s?.sensorNumber ?? _slot + 1;
    _hour = s?.hour ?? 9;
    _minute = s?.minute ?? 0;
    _enabled = s?.enabled ?? true;
    _label.text = s?.label ?? '';
    _time = TimeOfDay(hour: _hour, minute: _minute);
  }

  int _nextFreeSlot() {
    final repo = context.read<AppState>().repo;
    final used = repo.schedules.map((s) => s.slot).toSet();
    for (var i = 0; i < 6; i++) {
      if (!used.contains(i)) return i;
    }
    return 0;
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time);
    if (!mounted) return;
    if (t != null) {
      setState(() {
        _time = t;
        _hour = t.hour;
        _minute = t.minute;
      });
    }
  }

  // Reserve sensor bays already used by other slots.
  Set<int> _usedSensors() {
    final repo = context.read<AppState>().repo;
    final used = <int>{};
    for (final s in repo.schedules) {
      if (s.id == widget.schedule?.id) continue;
      used.add(s.sensorNumber);
    }
    return used;
  }

  Future<void> _save() async {
    final repo = context.read<AppState>().repo;
    final schedule = MedicineSchedule(
      id: widget.schedule?.id,
      slot: _slot,
      sensorNumber: _sensor,
      hour: _hour,
      minute: _minute,
      enabled: _enabled,
      label: _label.text.trim(),
    );

    try {
      if (widget.schedule?.id != null) {
        await repo.updateSchedule(widget.schedule!.id!, schedule);
      } else {
        await repo.addSchedule(schedule);
      }
      if (!mounted) return;
      Navigator.pop(context);
      showAppToast(
        context,
        widget.schedule?.id != null
            ? 'Dose updated and synced to the box'
            : 'Dose added and synced to the box',
      );
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, 'Could not save: $e', destructive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usedSensors = _usedSensors();
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.schedule == null ? 'Add dose' : 'Edit dose',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'These settings are pushed to the box immediately.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label (e.g. Morning dose)',
                hintText: 'Morning dose',
                prefixIcon: Icon(Icons.edit_outlined),
              ),
            ),
            const SizedBox(height: 20),
            Text('Compartment (day · morning/afternoon/night)',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var bay = 1; bay <= 6; bay++)
                  ChoiceChip(
                    avatar: Icon(
                      usedSensors.contains(bay)
                          ? Icons.warning_amber
                          : Icons.inventory_2_outlined,
                      size: 18,
                      color: usedSensors.contains(bay)
                          ? Colors.orange.shade800
                          : scheme.onSurfaceVariant,
                    ),
                    label: Text(MedicineSchedule.labelForBay(bay)),
                    selected: _sensor == bay,
                    onSelected: (_) => setState(() => _sensor = bay),
                  ),
              ],
            ),
            if (usedSensors.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.warning_amber,
                      size: 14, color: Colors.orange),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Orange icon = day already used by another dose.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.orange.shade800),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.schedule),
                    title: const Text('Time'),
                    trailing: Text(
                      TimeOfDay(hour: _hour, minute: _minute).format(context),
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    onTap: _pickTime,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  SwitchListTile(
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: Text(_enabled
                        ? 'Enabled — reminders will fire'
                        : 'Disabled — reminders paused'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save dose'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleTile extends StatelessWidget {
  final MedicineSchedule schedule;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _ScheduleTile({
    required this.schedule,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = schedule.enabled
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                schedule.bayLabel,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        schedule.label.isNotEmpty
                            ? schedule.label
                            : schedule.bayLabel,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.schedule,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(schedule.timeLabel,
                              style: theme.textTheme.bodySmall),
                          const SizedBox(width: 10),
                          Icon(Icons.inventory_2_outlined,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(schedule.bayLabel,
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            StatusChip(
              active: schedule.enabled,
              activeText: 'On',
              inactiveText: 'Off',
            ),
            IconButton(
              tooltip: 'Delete dose',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline,
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}