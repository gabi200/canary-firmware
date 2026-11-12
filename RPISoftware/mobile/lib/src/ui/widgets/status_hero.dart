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

/// A state mark that does not rely on colour alone: a dot for normal, a square for
/// attention, a triangle for danger, a ring for unknown.
class StateMark extends StatelessWidget {
  const StateMark({super.key, required this.color, this.size = 10});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(color)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color;
    final r = size.width / 2;
    final c = Offset(r, r);
    if (color == HazardColors.warning) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * 0.2)), fill);
    } else if (color == HazardColors.alarm || color == HazardColors.alarmFill || color == HazardColors.evacuation) {
      final path = Path()
        ..moveTo(r, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(path, fill);
    } else if (color == HazardColors.unknown) {
      canvas.drawCircle(
          c,
          r - 1,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6);
    } else {
      canvas.drawCircle(c, r, fill);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// The status block at the top of Home and the manager dashboard: a soft state
/// tint with a 1px state border, a short state line, one headline and one line
/// of body. Shared by the calm "all is well" and every in-between state.
class StatusBlock extends StatelessWidget {
  const StatusBlock({
    super.key,
    required this.color,
    this.stateLine,
    required this.title,
    this.subtitle,
    this.body,
    this.footer,
  });

  /// A [HazardColors] solid.
  final Color color;
  final String? stateLine;
  final String title;
  final String? subtitle;
  final String? body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final ink = palette.ink(color);
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        decoration: BoxDecoration(
          color: palette.tint(color),
          borderRadius: BorderRadius.circular(CanaryRadius.container),
          border: Border.all(color: palette.stateBorder(color)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (stateLine case final String line) ...[
              Row(children: [
                StateMark(color: color, size: 9),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(line, style: text.labelMedium!.copyWith(color: ink, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 10),
            ],
            Text(title, style: text.headlineMedium),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: text.titleMedium),
            ],
            if (body != null && body!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(body!, style: text.bodyMedium!.copyWith(color: palette.textSecondary)),
            ],
            if (footer != null) ...[const SizedBox(height: 6), footer!],
          ],
        ),
      ),
    );
  }
}

/// The status block when there is no alarm: verifying (amber, calm), hub
/// attention / danger, unknown, or all clear. [zoneLabel] names the verifying
/// incident's zone (building data, shown as sent). [stateLine] overrides the
/// short line above the headline (Home puts the live connection there).
class StatusHeroCard extends StatelessWidget {
  const StatusHeroCard({super.key, required this.status, this.zoneLabel, this.forManager = false, this.stateLine});
  final BuildingStatus status;
  final String? zoneLabel;
  final bool forManager;
  final String? stateLine;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (Color color, String title, String? subtitle, String body) = switch (status.kind) {
      BuildingStatusKind.verifying => (
          HazardColors.warning,
          l10n.verifyingTitle,
          [l10n.hazardName(status.incident!.hazardType), if (zoneLabel != null && zoneLabel!.isNotEmpty) zoneLabel!]
              .join(' · '),
          l10n.verifyingCalm,
        ),
      BuildingStatusKind.danger => (
          HazardColors.alarm,
          status.headline ?? l10n.statusDanger,
          null,
          l10n.dangerBody,
        ),
      BuildingStatusKind.attention => (
          HazardColors.warning,
          status.headline ?? l10n.statusNeedsAttention,
          null,
          l10n.attentionBody,
        ),
      BuildingStatusKind.unknown => (
          HazardColors.unknown,
          status.headline ?? l10n.statusUnknown,
          null,
          status.unreachable ? l10n.hubUnreachable : l10n.statusUnknownBody,
        ),
      BuildingStatusKind.loading => (
          HazardColors.unknown,
          l10n.loadingSensorStatus,
          null,
          '',
        ),
      BuildingStatusKind.clear || BuildingStatusKind.alarm => (
          HazardColors.normal,
          l10n.allClear,
          null,
          forManager ? l10n.noActiveHazardInBuilding : l10n.noActiveHazard,
        ),
    };
    final incident = status.incident;
    return StatusBlock(
      color: color,
      stateLine: stateLine,
      title: title,
      subtitle: subtitle,
      body: body,
      footer: incident == null ? null : ClassificationText(incident: incident),
    );
  }
}
