import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/medicine_schedule.dart';
import '../services/app_state.dart';
import 'common.dart';

/// Amber banner shown while the box is warning that medicine was removed
/// from a bay with no dose due. Separate from [ActiveAlarmBanner] so a
/// wrong-bay warning can sit alongside a live reminder without masking it.
///
/// Clears the moment the box reports the container back
/// (`wrong_bay_returned`), the correct dose is taken, or a caregiver stops
/// it - never on a timer.
class WrongBayBanner extends StatefulWidget {
  final bool isCaregiver;
  const WrongBayBanner({super.key, required this.isCaregiver});

  @override
  State<WrongBayBanner> createState() => _WrongBayBannerState();
}

class _WrongBayBannerState extends State<WrongBayBanner> {
  bool _stopping = false;

  Future<void> _stop() async {
    setState(() => _stopping = true);
    context.read<AppState>().repo.caregiverStopAlarm();
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    setState(() => _stopping = false);
    showAppToast(context, 'Wrong-bay warning stopped');
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final bay = appState.repo.wrongBayAlertBay ?? 0;
    // Compact amber strip: serious enough to act on, but visually distinct
    // from the red reminder/emergency banner so both can show at once.
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        color: Colors.deepOrange.shade700,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(width: 8),
                const Text(
                  'WRONG MEDICINE BAY',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${MedicineSchedule.labelForBay(bay)} was opened with no dose '
              'due. Put the container back in the box to stop the alarm.',
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                icon: _stopping
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('Stop Warning'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
