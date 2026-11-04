import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../state/mode_controller.dart';
import '../../theme.dart';

/// "DEMO" chip for the app bar while the hub is in demo mode. Phones only
/// follow the mode; the switch lives on the hub's web app.
class DemoChip extends ConsumerWidget {
  const DemoChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(hubModeProvider)?.isDemo ?? false)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Center(
        child: Chip(
          label: Text(context.l10n.modeBadge),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

/// Shown in demo mode while an incident is open in the real building, so a
/// real alarm is never hidden by the demo. No button: phones cannot switch.
class RealAlarmBanner extends ConsumerWidget {
  const RealAlarmBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(hubModeProvider);
    if (mode == null || !mode.isDemo || !mode.liveAlarm) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: HazardColors.alarm, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(context.l10n.modeRealAlarm,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}
