import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../widgets/common.dart';

/// Persistent banner shown at the top of every tab whenever a reminder or
/// emergency alarm is unacknowledged. Identical for patient and caregiver;
/// only the caregiver gets the "Stop Alarm" action, since a patient silences
/// the alarm by taking the dose.
class ActiveAlarmBanner extends StatefulWidget {
  final bool isCaregiver;
  const ActiveAlarmBanner({super.key, required this.isCaregiver});

  @override
  State<ActiveAlarmBanner> createState() => _ActiveAlarmBannerState();
}

class _ActiveAlarmBannerState extends State<ActiveAlarmBanner> {
  bool _stopping = false;

  Future<void> _stop() async {
    setState(() => _stopping = true);
    context.read<AppState>().repo.caregiverStopAlarm();
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    setState(() => _stopping = false);
    showAppToast(context, 'Alarm stop sent to box');
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isEmergency = appState.repo.isEmergencyAlarm;
    final color = Theme.of(context).colorScheme.error;
    // Emergency alert: hard red so it reads as a real emergency. The alarm
    // only clears once the emergency container is placed back in the box.
    final accentColor = isEmergency ? Colors.red.shade700 : color;
    // Keep the banner clear of the status bar (battery, clock, network
    // icons) and compact vertically so it doesn't push content far down.
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        color: accentColor,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isEmergency
                      ? Icons.emergency_outlined
                      : Icons.notifications_active,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  isEmergency
                      ? 'EMERGENCY TAKEN'
                      : 'MEDICINE ALARM ACTIVE',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              isEmergency
                  ? 'The emergency container was taken. Put it back in the '
                      'box to stop the alarm.'
                  : 'The patient alarm is ringing. Take the dose to stop it.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.95)),
            ),
            if (widget.isCaregiver) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _stopping ? null : _stop,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white),
                  backgroundColor: Colors.black.withValues(alpha: 0.15),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                icon: _stopping
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white),
                      )
                    : const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Stop Alarm'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}