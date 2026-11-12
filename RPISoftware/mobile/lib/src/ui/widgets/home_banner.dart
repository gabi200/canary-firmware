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
import 'classification_text.dart';

/// The one status at the top of the resident's home. Calm: "Totul e în regulă"
/// and "Locuința ta e monitorizată" on the green tint, with the live connection
/// on the state line. An alarm: the incident banner (fill by state, signs on
/// white discs), where it is for them, one line on what to do and the way into
/// the alarm screen. Anything in between (verifying, hub attention, unknown):
/// the status block shared with the manager dashboard.
class HomeStatusBanner extends StatelessWidget {
  const HomeStatusBanner({
    super.key,
    required this.status,
    this.where,
    this.zoneLabel,
    this.onOpenAlarm,
    this.connected = true,
  });
  final BuildingStatus status;

  /// Where the alarming incident is, relative to the resident.
  final HazardWhere? where;

  /// The verifying incident's room (building data, shown as sent).
  final String? zoneLabel;
  final VoidCallback? onOpenAlarm;

  /// The live connection to the hub, said on the calm state line.
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final live = connected ? l10n.live : l10n.reconnecting;
    return switch (status.kind) {
      BuildingStatusKind.alarm => _DangerBanner(incident: status.incident!, where: where, onOpen: onOpenAlarm),
      BuildingStatusKind.clear => StatusBlock(
          color: HazardColors.normal,
          stateLine: live,
          title: l10n.homeAllWell,
          body: l10n.homeMonitored,
        ),
      _ => StatusHeroCard(status: status, zoneLabel: zoneLabel),
    };
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
    final text = Theme.of(context).textTheme;
    final fill = HazardColors.bannerFill(incident.state);
    final ink = HazardColors.onBanner(incident.state);
    final hazard = l10n.hazardName(incident.hazardType);
    final where = this.where;
    final evacuation = incident.isEvacuation;
    return ClipRRect(
      borderRadius: BorderRadius.circular(CanaryRadius.container),
      child: ColoredBox(
        color: fill,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (evacuation) const HazardTape(),
            Padding(
              padding: EdgeInsets.fromLTRB(16, evacuation ? 18 : 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (evacuation) ...[
                        const SafetySignDisc(SafetySign.e002, size: 44),
                        const SizedBox(width: 8),
                      ],
                      SafetySignDisc(hazardSign(incident.hazardType), size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(evacuation ? l10n.evacuateNow : hazard,
                            style: text.headlineSmall!.copyWith(color: ink)),
                      ),
                    ],
                  ),
                  if (where != null) ...[
                    const SizedBox(height: 12),
                    Text(l10n.hazardWhereText(where), style: text.titleMedium!.copyWith(color: ink)),
                  ],
                  const SizedBox(height: 4),
                  ClassificationText(incident: incident, color: ink),
                  Text(
                    evacuation ? l10n.homeEvacuateLine : hazardDont(l10n, incident.hazardType),
                    style: text.bodyMedium!.copyWith(color: ink),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: fill),
                    icon: const SafetySignImage(SafetySign.e002, size: 26, decorative: true),
                    label: OneLineLabel(l10n.openEvacuationGuidance),
                    onPressed: onOpen,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The 4px black-and-amber strip along the top of an active-evacuation banner, and
/// nowhere else (DESIGN.md, Hazard tape).
class HazardTape extends StatelessWidget {
  const HazardTape({super.key, this.height = 4});
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(height: height, child: CustomPaint(painter: _TapePainter())),
      );
}

class _TapePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = HazardColors.tapeBlack);
    final amber = Paint()..color = HazardColors.tapeAmber;
    const stripe = 8.0;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width + size.height; x += stripe * 2) {
      final path = Path()
        ..moveTo(x, size.height)
        ..lineTo(x + size.height, 0)
        ..lineTo(x + size.height + stripe, 0)
        ..lineTo(x + stripe, size.height)
        ..close();
      canvas.drawPath(path, amber);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TapePainter old) => false;
}
