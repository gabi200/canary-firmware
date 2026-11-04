import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../models/incident.dart';
import '../../state/providers.dart';
import '../../state/dashboard_providers.dart';
import '../../theme.dart';

/// Sits outside the Navigator so pushed routes keep the latest assessment visible.
class ClassificationAlerts extends ConsumerWidget {
  const ClassificationAlerts({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final incidents = session == null
        ? const <Incident>[]
        : ref
            .watch(incidentControllerProvider)
            .incidents
            .where((i) =>
                i.buildingId == session.buildingId && i.hasClassification)
            .toList();
    if (incidents.isEmpty) return child;
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;
    return Column(children: [
      Material(
        color: context.palette.surface,
        child: SafeArea(
            bottom: false,
            child: ConstrainedBox(
              key: const ValueKey('classification-alerts'),
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.3),
              child: SingleChildScrollView(
                  child: Column(children: [
                for (final incident in incidents)
                  _Assessment(
                      key: ValueKey(incident.id),
                      incident: incident,
                      zoneLabel: prettyZone(labels, incident.primaryZoneId)),
              ])),
            )),
      ),
      Expanded(child: child),
    ]);
  }
}

class _Assessment extends StatelessWidget {
  const _Assessment(
      {super.key, required this.incident, required this.zoneLabel});
  final Incident incident;
  final String zoneLabel;

  @override
  Widget build(BuildContext context) {
    final signature = incident.signature!;
    final l10n = context.l10n;
    final palette = context.palette;
    final color = incident.isAlarming
        ? HazardColors.forState(incident.state)
        : HazardColors.info;
    String assessment(String? label, double? confidence) => [
          l10n.classificationName(label),
          if (confidence != null) '${l10n.count((confidence * 100).round())}%',
        ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
            liveRegion: true,
            child: Text(
              '${l10n.classificationTitle} · $zoneLabel',
              style: TextStyle(
                  color: palette.ink(color), fontWeight: FontWeight.w700),
            )),
        Text(
            '${l10n.classificationRule}: ${assessment(signature.label, signature.confidence)}',
            style: TextStyle(color: palette.text, fontWeight: FontWeight.w600)),
        if (incident.isAlarming)
          Text(
            l10n.incidentAlert(incident).title,
            style: TextStyle(
                color: palette.ink(color), fontWeight: FontWeight.w700),
          ),
        Text(
            '${l10n.classificationModel}: ${assessment(signature.shadowLabel, signature.shadowConfidence)}'
            '${signature.modelVersion == null ? '' : ' · ${signature.modelVersion}'}',
            style: TextStyle(color: palette.muted)),
        Text(
            '${l10n.classificationUpdated}: ${signature.ts == null ? l10n.classificationUnavailable : l10n.clockTime(signature.ts!)}',
            style: TextStyle(color: palette.muted)),
        if (incident.isAlarming)
          Text(l10n.incidentAlert(incident).body,
              style: TextStyle(
                  color: palette.ink(color), fontWeight: FontWeight.w600)),
        Text(l10n.classificationEstimate,
            style: TextStyle(color: palette.muted)),
        if (signature.evidence.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text(l10n.classificationEvidence),
            children: [
              for (final evidence in signature.evidence)
                Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(evidence))
            ],
          ),
      ]),
    );
  }
}
