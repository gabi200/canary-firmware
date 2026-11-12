import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/evacuation.dart';
import '../../theme.dart';
import 'safety_sign.dart';

/// Ordered, text-first evacuation directions with a visible route spine.
class RouteLine extends StatelessWidget {
  const RouteLine({super.key, required this.waypoints, this.avoidZoneName});

  final List<Waypoint> waypoints;
  final String? avoidZoneName;

  @override
  Widget build(BuildContext context) {
    if (waypoints.isEmpty) return const SizedBox.shrink();
    final avoidName = avoidZoneName?.trim();
    return Stack(
      children: [
        Positioned(
          left: 14,
          top: 18,
          bottom: 36,
          child: Container(width: 4, color: HazardColors.routeLine),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < waypoints.length; i++) ...[
              _Stop(
                waypoint: waypoints[i],
                index: i,
                total: waypoints.length,
              ),
              if (i == 0 && avoidName != null && avoidName.isNotEmpty)
                _AvoidRow(name: avoidName),
            ],
          ],
        ),
      ],
    );
  }
}

class _Stop extends StatelessWidget {
  const _Stop({required this.waypoint, required this.index, required this.total});

  final Waypoint waypoint;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final isFirst = index == 0;
    final isLast = index == total - 1;
    final hint = waypoint.hint.trim();
    final dotColor = isLast ? HazardColors.routeLine
        : (isFirst ? HazardColors.start : HazardColors.routeLine);
    final l10n = context.l10n;
    // Waypoint label/hint are building data from the server: shown as sent.
    return Semantics(
      container: true,
      label: '${l10n.routeStep(index + 1, total, waypoint.label)}${hint.isEmpty ? '' : ' $hint'}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: Container(
                    width: isFirst || isLast ? 22 : 16,
                    height: isFirst || isLast ? 22 : 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isFirst || isLast ? dotColor : context.palette.surface,
                      border: Border.all(color: dotColor, width: 3),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isFirst)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: HazardColors.start,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(l10n.startHere,
                            style: const TextStyle(color: HazardColors.onHazard, fontSize: 14,
                                fontWeight: FontWeight.w600)),
                      ),
                    if (isFirst) const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isLast) ...[
                          const SafetySignImage(SafetySign.e007, size: 24, decorative: true),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(waypoint.label,
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                                  color: context.palette.text)),
                        ),
                      ],
                    ),
                    if (hint.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(hint, style: TextStyle(fontSize: 14, color: context.palette.muted)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AvoidRow extends StatelessWidget {
  const _AvoidRow({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final text = context.l10n.avoidZone(name);
    return Semantics(label: text, child: ExcludeSemantics(child: Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CustomPaint(
            size: const Size(32, 52),
            painter: _AvoidDashPainter(background: context.palette.surface),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                const SafetySignImage(SafetySign.p001, size: 24, decorative: true),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(text,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                          color: HazardColors.alarm)),
                ),
              ],
            ),
          ),
        ],
      ),
    )));
  }
}

class _AvoidDashPainter extends CustomPainter {
  _AvoidDashPainter({required this.background});

  /// The screen behind the route, so the dashes cut the green spine.
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = this.background;
    final dash = Paint()
      ..color = HazardColors.alarm
      ..strokeWidth = 4;
    canvas.drawRect(Rect.fromLTWH(12, 0, 8, size.height), background);
    for (var y = 0.0; y < size.height; y += 12) {
      canvas.drawLine(Offset(16, y), Offset(16, y + 6 > size.height ? size.height : y + 6), dash);
    }
  }

  @override
  bool shouldRepaint(_AvoidDashPainter old) => old.background != background;
}
