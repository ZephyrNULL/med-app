import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/alarm_sound_service.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../widgets/common.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final profile = appState.profile;
    final repo = appState.repo;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: profile == null
          ? _ProfileUnavailable(onReload: appState.reloadProfile)
          : RefreshIndicator(
              onRefresh: () async {
                await appState.reloadProfile();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Header
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        backgroundColor: scheme.primary.withValues(alpha: 0.12),
                        child: Icon(
                          appState.isCaregiver
                              ? Icons.volunteer_activism_outlined
                              : Icons.person_outline,
                          color: scheme.primary,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(profile.fullName,
                                style: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.bold)),
                            Text(profile.email,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant)),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    appState.isCaregiver
                                        ? Icons.support_agent
                                        : Icons.person,
                                    size: 16,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    appState.isCaregiver
                                        ? 'Caregiver'
                                        : 'Patient',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Box connection
                  const SectionHeader(title: 'Box & connection'),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.sensors),
                          title: const Text('Device ID'),
                          trailing: Text(
                            repo.deviceId ?? 'Not paired',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const Divider(height: 1, indent: 56),
                        ListTile(
                          leading: Icon(
                            repo.mqttConnected
                                ? Icons.link
                                : Icons.link_off,
                            color: repo.mqttConnected
                                ? Colors.green
                                : Colors.orange,
                          ),
                          title: const Text('MQTT connection'),
                          trailing: StatusChip(
                            active: repo.mqttConnected,
                            activeText: 'Online',
                            inactiveText: 'Offline',
                          ),
                        ),
                        const Divider(height: 1, indent: 56),
                        ListTile(
                          leading: const Icon(Icons.schedule),
                          title: const Text('Last synced'),
                          trailing: Text(
                            repo.lastSynced != null
                                ? DateFormat('MMM d, HH:mm')
                                    .format(repo.lastSynced!)
                                : 'Never',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Notification & alarm sound
                  const SectionHeader(title: 'Notifications & alarms'),
                  const SizedBox(height: 8),
                  const _AlarmSettingsCard(),
                  const SizedBox(height: 16),

                  // Personal info
                  const SectionHeader(title: 'Personal information'),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        _divider(),
                        _infoTile(context, Icons.phone_outlined, 'Phone',
                            profile.phone ?? '—'),
                        _divider(),
                        _infoTile(
                            context,
                            Icons.cake_outlined,
                            'Date of birth',
                            profile.dateOfBirth != null
                                ? DateFormat('MMM d, yyyy')
                                    .format(profile.dateOfBirth!)
                                : '—'),
                        _divider(),
                        _infoTile(context, Icons.face_outlined, 'Gender',
                            profile.gender ?? '—'),
                        _divider(),
                        _infoTile(
                            context,
                            Icons.medical_information_outlined,
                            'Allergies',
                            profile.allergies ?? '—'),
                        _divider(),
                        _infoTile(context, Icons.bloodtype_outlined, 'Blood group',
                            profile.bloodGroup ?? '—'),
                        _divider(),
                        _infoTile(
                            context,
                            Icons.emergency_outlined,
                            'Emergency contact',
                            profile.emergencyContactName != null
                                ? '${profile.emergencyContactName} — ${profile.emergencyContactPhone ?? ''}'
                                : '—'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Care team (role-dependent)
                  if (appState.isCaregiver)
                    const _CaregiverLinks()
                  else
                    _PatientCareTeam(patientId: profile.id),

                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const EditProfileScreen()),
                    ),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit profile'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                      side: BorderSide(color: scheme.error.withValues(alpha: 0.6)),
                    ),
                    onPressed: () async {
                      await SupabaseService.signOut();
                      appState.clear();
                      if (!context.mounted) return;
                      Navigator.pushNamedAndRemoveUntil(
                          context, '/login', (route) => false);
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _divider() => const Divider(height: 1, indent: 56);

  Widget _infoTile(
      BuildContext context, IconData icon, String label, String value) {
    return ListTile(
      leading: Icon(icon, size: 22),
      title: Text(label),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _AlarmSettingsCard extends StatelessWidget {
  const _AlarmSettingsCard();

  @override
  Widget build(BuildContext context) {
    final alarms = AlarmSoundService();
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: alarms.selectedSoundNotifier,
            builder: (context, selectedId, _) {
              final current = AlarmSoundService.sounds
                  .where((s) => s.id == selectedId)
                  .toList();
              final currentName =
                  current.isEmpty ? 'Classic beeps' : current.first.name;
              return ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Alarm sound'),
                subtitle: Text(currentName),
                trailing: const Icon(Icons.expand_more),
                onTap: () => _showSoundPicker(context, alarms),
              );
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          ValueListenableBuilder<double>(
            valueListenable: alarms.volumeNotifier,
            builder: (context, volume, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.volume_up_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      value: volume.clamp(0.0, 1.0),
                      onChanged: (v) => alarms.setVolume(v),
                    ),
                  ),
                  Text(
                    '${(volume * 100).round()}%',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSoundPicker(BuildContext context, AlarmSoundService alarms) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Alarm sound'),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        content: ValueListenableBuilder<String>(
          valueListenable: alarms.selectedSoundNotifier,
          builder: (context, selectedId, _) => RadioGroup<String>(
            groupValue: selectedId,
            onChanged: (v) {
              if (v == null) return;
              alarms.preview(v);
              alarms.setSound(v);
            },
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final sound in AlarmSoundService.sounds)
                    RadioListTile<String>(
                      value: sound.id,
                      dense: true,
                      title: Text(sound.name),
                    ),
                ],
              ),
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _ProfileUnavailable extends StatelessWidget {
  final Future<void> Function() onReload;
  const _ProfileUnavailable({required this.onReload});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off_outlined,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Profile not loaded',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'We couldn\'t load your profile. Tap reload to re-create it from your account.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async => onReload(),
              icon: const Icon(Icons.refresh),
              label: const Text('Reload profile'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaregiverLinks extends StatelessWidget {
  const _CaregiverLinks();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: SupabaseService.fetchLinksForCaregiver(
        SupabaseService.currentUser!.id,
      ),
      builder: (context, snap) {
        final links = (snap.data ?? []) as List;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(title: 'Linked patients'),
            const SizedBox(height: 8),
            Card(
              clipBehavior: Clip.antiAlias,
              child: links.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No patients linked yet.\nAsk a patient to '
                        'send you a pairing request from their profile.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : Column(
                      children: [
                        for (final link in links)
                          ListTile(
                            leading: const Icon(Icons.person),
                            title: Text(
                                'Patient ${link['patient_id']?.toString().characters.take(8)}'),
                            subtitle: Text('Status: ${link['status']}'),
                            trailing: StatusChip(
                              active: (link['status'] ?? '') == 'active',
                              activeText: 'Active',
                              inactiveText: 'Pending',
                            ),
                            shape: const Border(),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _PatientCareTeam extends StatelessWidget {
  final String patientId;
  const _PatientCareTeam({required this.patientId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder(
      future: SupabaseService.fetchLinksForPatient(patientId),
      builder: (context, snap) {
        final links = (snap.data ?? []) as List;
        final active =
            links.where((l) => (l['status'] ?? '') == 'active').length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(title: 'Care team'),
            const SizedBox(height: 8),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.support_agent),
                    title: Text(
                      '$active caregiver${active == 1 ? '' : 's'} linked',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      active > 0
                          ? 'Your caregiver can monitor alerts and stop the alarm remotely.'
                          : 'No caregiver linked yet. Ask someone to set up a caregiver account and link to your email.',
                    ),
                    trailing: const Icon(Icons.health_and_safety),
                  ),
                  for (final link in links)
                    if ((link['status'] ?? '') == 'active')
                      ListTile(
                        leading: const Icon(Icons.volunteer_activism),
                        title: Text(
                            '${link['caregiver_id']?.toString().characters.take(8)}'),
                        subtitle: const Text('Status: active'),
                        shape: const Border(),
                      ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}