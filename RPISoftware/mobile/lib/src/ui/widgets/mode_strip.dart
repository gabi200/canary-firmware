import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../state/mode_controller.dart';
import '../../theme.dart';

/// "Demo" badge for the app bar while the hub is in demo mode: a neutral
/// outlined pill, never a hazard colour (DESIGN.md, Neutral Demo Rule). Phones
/// only follow the mode; the switch lives on the hub's web app.
class DemoChip extends ConsumerWidget {
  const DemoChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(hubModeProvider)?.isDemo ?? false)) return const SizedBox.shrink();
    final palette = context.palette;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(CanaryRadius.control),
          border: Border.all(color: palette.hairlineStrong),
        ),
        child: Text(context.l10n.modeBadge,
            style: Theme.of(context).textTheme.labelMedium!.copyWith(color: palette.textSecondary)),
      ),
    );
  }
}

/// The Canary wordmark's yellow dot, before the title on the resident's bar.
class WordmarkDot extends StatelessWidget {
  const WordmarkDot({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: context.palette.wordmarkDot, shape: BoxShape.circle),
        ),
      );
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
        decoration: BoxDecoration(
            color: HazardColors.alarmFill, borderRadius: BorderRadius.circular(CanaryRadius.container)),
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Text(context.l10n.modeRealAlarm,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}
