import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../logic/hazard_advice.dart';
import '../../logic/relative_location.dart';
import '../../models/incident.dart';
import '../../state/building_status.dart';
import '../../theme.dart';
import 'one_line_label.dart';
import 'safety_sign.dart';
import 'status_hero.dart';

/// The one big status at the top of the resident's home. Calm: a shield,
/// "Totul e în regulă" and "Locuința ta e monitorizată". An alarm: the danger
/// in red, where it is for them, one line on what to do and the way into the
/// alarm screen. Anything in between (verifying, hub attention, unknown): the
/// status card shared with the manager dashboard.
class HomeStatusBanner extends StatelessWidget {
  const HomeStatusBanner({super.key, required this.status, this.where, this.zoneLabel, this.onOpenAlarm});
  final BuildingStatus status;

  /// Where the alarming incident is, relative to the resident.
  final HazardWhere? where;

  /// The verifying incident's room (building data, shown as sent).
  final String? zoneLabel;
  final VoidCallback? onOpenAlarm;

  @override
  Widget build(BuildContext context) => switch (status.kind) {
        BuildingStatusKind.alarm => _DangerBanner(incident: status.incident!, where: where, onOpen: onOpenAlarm),
        BuildingStatusKind.clear => const _AllWellBanner(),
        _ => StatusHeroCard(status: status, zoneLabel: zoneLabel),
      };
}

class _AllWellBanner extends StatelessWidget {
  const _AllWellBanner();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final green = palette.ink(HazardColors.normal);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.tint(HazardColors.normal),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: green.withAlpha(110), width: 1.5),
      ),
      child: Semantics(
        container: true,
        child: Row(
          children: [
            Icon(Icons.verified_user, size: 56, color: green),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.homeAllWell,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: palette.text)),
                  const SizedBox(height: 4),
                  Text(l10n.homeMonitored, style: TextStyle(fontSize: 16, color: palette.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DangerBanner extends StatelessWidget {
  const _DangerBanner({required this.incident, required this.where, required this.onOpen});
  final Incident incident;
  final HazardWhere? where;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final color = HazardColors.forState(incident.state);
    final hazard = l10n.hazardName(incident.hazardType);
    final where = this.where;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (incident.isEvacuation) ...[
                  const SafetySignImage(SafetySign.e002, size: 48),
                  const SizedBox(width: 8),
                ],
                SafetySignImage(hazardSign(incident.hazardType), size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    incident.isEvacuation ? l10n.evacuateNow : hazard.toUpperCase(),
                    style: const TextStyle(color: HazardColors.onHazard, fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
            if (where != null) ...[
              const SizedBox(height: 12),
              Text(l10n.hazardWhereText(where),
                  style: const TextStyle(color: HazardColors.onHazard, fontSize: 18, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: 6),
            Text(
              incident.isEvacuation ? l10n.homeEvacuateLine : hazardDont(l10n, incident.hazardType),
              style: const TextStyle(color: HazardColors.onHazard, fontSize: 16),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: HazardColors.surface, foregroundColor: color),
              icon: const SafetySignImage(SafetySign.e002, size: 28, decorative: true),
              label: OneLineLabel(l10n.openEvacuationGuidance),
              onPressed: onOpen,
            ),
          ],
        ),
      ),
    );
  }
}
