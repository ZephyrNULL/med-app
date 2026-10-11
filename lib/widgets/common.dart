import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';

/// Provider convenience helpers.
AppState appStateOf(BuildContext context) => context.read<AppState>();

/// App-wide toast built on ScaffoldMessenger SnackBars.
void showAppToast(
  BuildContext context,
  String message, {
  bool destructive = false,
}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: destructive ? scheme.error : null,
        duration: const Duration(seconds: 3),
      ),
    );
}

/// Prompts the user to type their box's device id (printed on the
/// hardware). Returns the trimmed device id, or null if cancelled.
Future<String?> showPairBoxDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => const _PairBoxDialog(),
  );
}

class _PairBoxDialog extends StatefulWidget {
  const _PairBoxDialog();

  @override
  State<_PairBoxDialog> createState() => _PairBoxDialogState();
}

class _PairBoxDialogState extends State<_PairBoxDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Connect your box'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Box ID',
              hintText: 'carecube-001',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Find the device id on the sticker on the bottom of your box.',
            style: textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

/// Shared UI bits used across screens.

class StatusChip extends StatelessWidget {
  final bool active;
  final String activeText;
  final String inactiveText;
  const StatusChip({
    super.key,
    required this.active,
    this.activeText = 'Active',
    this.inactiveText = 'Off',
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? Colors.green.shade700 : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? Colors.green.withValues(alpha: 0.15)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        active ? activeText : inactiveText,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Compact card used across dashboard grids.
class InfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? accent;
  final String? footnote;
  const InfoCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.accent,
    this.footnote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = accent ?? theme.colorScheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const Spacer(),
                if (footnote != null)
                  Text(
                    footnote!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(value,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

/// Shown in place of live box data (readings, schedules, connection details)
/// while the box is not reporting. Keeps persisted history from being
/// presented as if it were current.
class BoxOfflineCard extends StatelessWidget {
  final String? message;
  const BoxOfflineCard({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Box not reporting',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              message ??
                  'Your Care Cube is offline, so live data is hidden until it '
                      'starts reporting again.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section header with an optional trailing widget.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader({super.key, required this.title, this.trailing});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (trailing != null) ?trailing,
      ],
    );
  }
}

/// Card that shows realtime MQTT connection status.
class ConnectionStatusCard extends StatelessWidget {
  final bool connected;
  final String? lastSynced;
  final VoidCallback? onTap;
  const ConnectionStatusCard({
    super.key,
    required this.connected,
    this.lastSynced,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = connected ? Colors.green.shade700 : Colors.orange.shade800;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                connected ? Icons.link : Icons.link_off,
                color: color,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connected ? 'Box connected' : 'Box offline',
                      style: TextStyle(
                          color: color, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lastSynced != null
                          ? 'Last synced: $lastSynced'
                          : 'Waiting for box data',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                  ],
                ),
              ),
              _PulseDot(connected: connected),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseDot extends StatelessWidget {
  final bool connected;
  const _PulseDot({required this.connected});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: connected ? Colors.green : Colors.grey.shade400,
        boxShadow: connected
            ? [
                BoxShadow(
                  color: Colors.green.withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
    );
  }
}

/// Horizontal bar showing progress n/total.
class ProgressBarLabeled extends StatelessWidget {
  final double fraction;
  final String label;
  final Color? color;
  const ProgressBarLabeled({
    super.key,
    required this.fraction,
    required this.label,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const Spacer(),
            Text(
              '${(fraction * 100).round()}%',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: c, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: c,
          ),
        ),
      ],
    );
  }
}