import 'package:flutter/material.dart';

import '../../models/evacuation.dart';
import '../../theme.dart';
import '../../../l10n/gen/app_localizations.dart';

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
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).routeStep(index + 1, total, waypoint.label, hint.isEmpty ? '' : ' $hint'),
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
                      color: isFirst || isLast ? dotColor : HazardColors.surface,
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
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(AppLocalizations.of(context).startHere,
                            style: const TextStyle(color: HazardColors.onHazard, fontSize: 14,
                                fontWeight: FontWeight.bold)),
                      ),
                    if (isFirst) const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isLast) ...[
                          const Icon(Icons.flag, color: HazardColors.routeLine, size: 24),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(waypoint.label,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                                  color: HazardColors.text)),
                        ),
                      ],
                    ),
                    if (hint.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(hint, style: const TextStyle(fontSize: 14, color: HazardColors.muted)),
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
    final label = AppLocalizations.of(context).avoid(name);
    return Semantics(label: label, child: ExcludeSemantics(child: Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CustomPaint(
            size: const Size(32, 52),
            painter: _AvoidDashPainter(),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.block, color: HazardColors.alarm, size: 24),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(label,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
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
  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = HazardColors.surface;
    final dash = Paint()
      ..color = HazardColors.alarm
      ..strokeWidth = 4;
    canvas.drawRect(Rect.fromLTWH(12, 0, 8, size.height), background);
    for (var y = 0.0; y < size.height; y += 12) {
      canvas.drawLine(Offset(16, y), Offset(16, y + 6 > size.height ? size.height : y + 6), dash);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
