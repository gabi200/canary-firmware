import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../state/building_status.dart';
import '../../theme.dart';
import 'status_pill.dart';
import 'classification_text.dart';

/// App-bar pill matching [status] (never "all clear" while something is open).
class BuildingStatusPill extends StatelessWidget {
  const BuildingStatusPill({super.key, required this.status});
  final BuildingStatus status;

  @override
  Widget build(BuildContext context) {
    final kind = status.kind;
    return StatusPill(
      state: status.pillState,
      label: kind == BuildingStatusKind.clear ? context.l10n.allClear : null,
      color: switch (kind) {
        BuildingStatusKind.danger || BuildingStatusKind.attention || BuildingStatusKind.unknown ||
        BuildingStatusKind.loading =>
          HazardColors.forLevel(status.pillState),
        _ => null,
      },
    );
  }
}

/// The big card at the top when there is no alarm: verifying (amber, calm),
/// hub attention / danger, unknown, or all clear. [zoneLabel] names the
/// verifying incident's zone (building data, shown as sent).
class StatusHeroCard extends StatelessWidget {
  const StatusHeroCard({super.key, required this.status, this.zoneLabel, this.forManager = false});
  final BuildingStatus status;
  final String? zoneLabel;
  final bool forManager;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (IconData icon, Color color, String title, String? subtitle, String body) = switch (status.kind) {
      BuildingStatusKind.verifying => (
          Icons.manage_search,
          HazardColors.warning,
          l10n.verifyingTitle,
          [l10n.hazardName(status.incident!.hazardType), if (zoneLabel != null && zoneLabel!.isNotEmpty) zoneLabel!]
              .join(' · '),
          l10n.verifyingCalm,
        ),
      BuildingStatusKind.danger => (
          Icons.warning_rounded,
          HazardColors.alarm,
          status.headline ?? l10n.statusDanger,
          null,
          l10n.dangerBody,
        ),
      BuildingStatusKind.attention => (
          Icons.error_outline,
          HazardColors.warning,
          status.headline ?? l10n.statusNeedsAttention,
          null,
          l10n.attentionBody,
        ),
      BuildingStatusKind.unknown => (
          Icons.help_outline,
          HazardColors.unknown,
          status.headline ?? l10n.statusUnknown,
          null,
          status.unreachable ? l10n.hubUnreachable : l10n.statusUnknownBody,
        ),
      BuildingStatusKind.loading => (
          Icons.hourglass_empty,
          HazardColors.unknown,
          l10n.loadingSensorStatus,
          null,
          '',
        ),
      BuildingStatusKind.clear || BuildingStatusKind.alarm => (
          Icons.verified_user,
          HazardColors.normal,
          l10n.allClear,
          null,
          forManager ? l10n.noActiveHazardInBuilding : l10n.noActiveHazard,
        ),
    };
    return Card(
      margin: EdgeInsets.zero,
      color: context.palette.tint(color),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
            color: context.palette.ink(color).withAlpha(status.kind == BuildingStatusKind.clear ? 0 : 160), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, color: context.palette.ink(color), size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ],
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(body),
                  ],
                  if (status.incident case final incident?)
                    ClassificationText(incident: incident),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
