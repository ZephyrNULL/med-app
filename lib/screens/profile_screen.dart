import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/alarm_sound_service.dart';
import '../services/app_state.dart';
import '../services/supabase_service.dart';
import '../services/system_ringtone_service.dart';
import '../widgets/common.dart';
import 'edit_profile_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final profile = appState.profile;
    final repo = appState.repo;
    final online = repo.boxOnline;
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
                        if (online) ...[
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
                        ],
                        ListTile(
                          leading: Icon(
                            online ? Icons.link : Icons.link_off,
                            color: online ? Colors.green : Colors.orange,
                          ),
                          title: const Text('Box connection'),
                          trailing: StatusChip(
                            active: online,
                            activeText: 'Online',
                            inactiveText: 'Offline',
                          ),
                        ),
                        const Divider(height: 1, indent: 56),
                        ListTile(
                          leading: const Icon(Icons.schedule),
                          title: const Text('Last synced'),
                          trailing: Text(
                            online && repo.lastSynced != null
                                ? DateFormat('MMM d, HH:mm')
                                    .format(repo.lastSynced!)
                                : 'Offline',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const _ConnectBoxCard(),
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

                  // Care team (role-dependent). Hidden while the box is
                  // offline so persisted relationships are not shown as live.
                  if (online) ...[
                    if (appState.isCaregiver)
                      const _CaregiverLinks()
                    else
                      _PatientCareTeam(patientId: profile.id),
                    const SizedBox(height: 16),
                  ],

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

  /// Connect the app to an ESP32 box by typing its device id.
  ///
  /// Patients pair the box into their own account; caregivers instead ask
  /// the server to link them to the patient who already paired that device id
  /// (boxes are patient-owned, both roles then load the same box).
  static Future<void> _connectBox(BuildContext context) async {
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

class _ConnectBoxCard extends StatelessWidget {
  const _ConnectBoxCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final appState = context.watch<AppState>();
    final repo = appState.repo;
    final connected = repo.boxOnline;
    final deviceId = repo.deviceId;
    final paired = deviceId != null;
    final caregiver = appState.isCaregiver;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  connected ? Icons.sensors : Icons.add_link,
                  color: connected ? Colors.green.shade700 : scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    connected
                        ? 'Box connected'
                        : (paired
                            ? 'Box offline'
                            : (caregiver
                                ? 'Connect to your patient\u2019s box'
                                : 'Connect to your box')),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              caregiver
                  ? 'This links you to the patient who owns the box '
                      'with this device id, so you see their live '
                      'readings, dose alerts and can stop their alarm. '
                      'Type the device id printed on the sticker on the '
                      'bottom of the box to connect.'
                  : 'Your phone talks to the ESP32 medicine box over MQTT '
                      'to receive live temperature, humidity and dose '
                      'alerts. Type the device id printed on the sticker '
                      'on the bottom of the box to pair it with this '
                      'account. Once connected, live readings appear on '
                      'the Home tab and reminders ring automatically at '
                      'dose time.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => ProfileScreen._connectBox(context),
              icon: const Icon(Icons.link),
              label: Text(
                connected || paired
                    ? 'Pair/connect a different box'
                    : (caregiver
                        ? 'Connect to patient\u2019s box'
                        : 'Connect to ESP32 box'),
              ),
            ),
            if (deviceId != null && connected) ...[
              const SizedBox(height: 8),
              Text(
                'Current box: $deviceId',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
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
              final currentName = alarms.selectedSoundName;
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
    final sys = SystemRingtoneService();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Alarm sound'),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 520),
          child: FutureBuilder<List<Map<String, String>>>(
            future: sys.listTones(),
            builder: (context, snap) {
              final tones = snap.data ?? const <Map<String, String>>[];
              String labelFor(String id) {
                final sys = SystemRingtoneService();
                if (!sys.isSystemId(id)) {
                  for (final s in AlarmSoundService.sounds) {
                    if (s.id == id) return s.name;
                  }
                  return 'Tone';
                }
                for (final tone in tones) {
                  if (sys.idOfUri(tone['uri'] ?? '') == id) {
                    return tone['name'] ?? 'Ringtone';
                  }
                }
                return 'Ringtone';
              }

              return ValueListenableBuilder<String>(
                valueListenable: alarms.selectedSoundNotifier,
                builder: (context, selectedId, _) => RadioGroup<String>(
                  groupValue: selectedId,
                  onChanged: (v) {
                    if (v == null) return;
                    alarms.preview(v);
                    alarms.setSound(v, name: labelFor(v));
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
                        const Divider(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Phone ringtones',
                              style: Theme.of(dialogContext)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                      color: Theme.of(dialogContext)
                                          .colorScheme
                                          .onSurfaceVariant),
                            ),
                          ),
                        ),
                        if (tones.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                                'No system ringtones available on this device.'),
                          )
                        else
                          for (final tone in tones)
                            RadioListTile<String>(
                              value: sys.idOfUri(tone['uri'] ?? ''),
                              dense: true,
                              title: Text(
                                tone['name'] ?? 'Ringtone',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              secondary: IconButton(
                                icon: const Icon(Icons.play_circle_outline,
                                    size: 20),
                                onPressed: () =>
                                    alarms.preview(sys.idOfUri(tone['uri'] ?? '')),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () async {
              await alarms.stopPreview();
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
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