import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../models/care_profile.dart';
import '../../models/check_in.dart';
import '../../services/api_client.dart';
import '../../state/care_providers.dart';
import '../../theme.dart';
import 'one_line_label.dart';

/// Alarm screen: "Who else is at home?" — one row per household member from
/// the resident's emergency profiles, with big Outside / Still inside / Needs
/// help buttons that post a care check-in. Renders nothing when there are no
/// household profiles; a failed load or send shows a short error with retry
/// and never blocks the resident's own evacuation.
class HouseholdCheckIn extends ConsumerWidget {
  const HouseholdCheckIn({super.key, required this.incidentId});
  final String incidentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(careProfilesProvider);
    final people = async.valueOrNull?.where((p) => !p.isSelf).toList();
    if (people == null) {
      final error = async.error;
      if (error == null || (error is ApiException && error.statusCode == 503)) return const SizedBox.shrink();
      return Row(children: [
        const Icon(Icons.sync_problem, color: HazardColors.warning),
        const SizedBox(width: 8),
        Expanded(child: Text(l10n.householdLoadFailed, style: const TextStyle(fontSize: 15))),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => ref.read(careProfilesProvider.notifier).refresh(),
          child: Text(l10n.retry),
        ),
      ]);
    }
    if (people.isEmpty) return const SizedBox.shrink();
    final checkIns = ref.watch(careCheckInProvider(incidentId));
    final controller = ref.read(careCheckInProvider(incidentId).notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l10n.householdTitle,
              style: TextStyle(color: context.palette.text, fontSize: 20, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 10),
        for (final p in people) ...[
          _PersonRow(
            profile: p,
            checkIn: checkIns[p.id],
            onSend: (status) => controller.send(p.id, status),
            onChange: () => controller.change(p.id),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.profile, required this.checkIn, required this.onSend, required this.onChange});
  final CareProfile profile;
  final CareCheckIn? checkIn;
  final ValueChanged<CheckInStatus> onSend;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = checkIn;
    final needs = profile.needs.map(l10n.careNeed).join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: context.palette.surface,
        border: Border.all(color: context.palette.divider, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: l10n.householdPersonSemantics(profile.displayName),
            excludeSemantics: true,
            child: Text(profile.displayName,
                style: TextStyle(color: context.palette.text, fontSize: 19, fontWeight: FontWeight.w600)),
          ),
          if (needs.isNotEmpty)
            Text(needs, style: TextStyle(color: context.palette.muted, fontSize: 14)),
          const SizedBox(height: 10),
          if (c == null)
            _StatusButtons(onSend: onSend)
          else if (c.sending)
            Row(children: [
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(child: Text('${l10n.householdStatus(c.status)} · ${l10n.householdSending}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
            ])
          else if (c.failed) ...[
            Row(children: [
              const Icon(Icons.error, color: HazardColors.alarm),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${l10n.householdStatus(c.status)} · ${l10n.householdFailed}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ]),
            Wrap(spacing: 8, children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => onSend(c.status),
                child: Text(l10n.retry),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onChange,
                child: Text(l10n.change),
              ),
            ]),
          ] else
            Row(children: [
              const Icon(Icons.check_circle, color: HazardColors.normal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l10n.householdSent(l10n.householdStatus(c.status)),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onChange,
                child: Text(l10n.change),
              ),
            ]),
        ],
      ),
    );
  }
}

class _StatusButtons extends StatelessWidget {
  const _StatusButtons({required this.onSend});
  final ValueChanged<CheckInStatus> onSend;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const text = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
    final out = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: HazardColors.normal,
        foregroundColor: HazardColors.onHazard,
        minimumSize: const Size.fromHeight(52),
        textStyle: text,
      ),
      icon: const Icon(Icons.directions_walk),
      label: OneLineLabel(l10n.householdOut),
      onPressed: () => onSend(CheckInStatus.safeOutside),
    );
    final inside = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: context.palette.text,
        minimumSize: const Size.fromHeight(52),
        side: BorderSide(color: context.palette.text, width: 1.5),
        textStyle: text,
      ),
      icon: const Icon(Icons.home_outlined),
      label: OneLineLabel(l10n.householdInside),
      onPressed: () => onSend(CheckInStatus.safeInside),
    );
    final help = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: HazardColors.alarm,
        foregroundColor: HazardColors.onHazard,
        minimumSize: const Size.fromHeight(52),
        textStyle: text,
      ),
      icon: const Icon(Icons.sos),
      label: OneLineLabel(l10n.householdNeedsHelp),
      onPressed: () => onSend(CheckInStatus.needsHelp),
    );
    return LayoutBuilder(builder: (context, constraints) {
      final narrow =
          !labelsFit(context, [l10n.householdOut, l10n.householdInside], text, (constraints.maxWidth - 8) / 2);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (narrow) ...[out, const SizedBox(height: 8), inside]
          else
            Row(children: [Expanded(child: out), const SizedBox(width: 8), Expanded(child: inside)]),
          const SizedBox(height: 8),
          help,
        ],
      );
    });
  }
}
