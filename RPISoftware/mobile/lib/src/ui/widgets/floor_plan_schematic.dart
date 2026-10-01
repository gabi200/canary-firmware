import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/floor_plan_layout.dart';
import '../../theme.dart';

/// Point-based route illustration; the caller supplies all visible copy.
class FloorPlanSchematic extends StatelessWidget {
  const FloorPlanSchematic({
    super.key,
    required this.layout,
    required this.startLabel,
    required this.notToScaleLabel,
    required this.assemblyLabel,
    required this.semanticsLabel,
  });

  final FloorPlanLayout layout;
  final String startLabel;
  final String notToScaleLabel;
  final String assemblyLabel;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: semanticsLabel,
    child: ExcludeSemantics(
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _FloorPlanPainter(
                layout, startLabel, assemblyLabel, DefaultTextStyle.of(context).style.fontFamily)),
            Positioned(
              top: 8,
              right: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: HazardColors.surface,
                  border: Border.all(color: HazardColors.divider),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Text(
                    notToScaleLabel,
                    style: const TextStyle(
                      color: HazardColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _FloorPlanPainter extends CustomPainter {
  _FloorPlanPainter(this.layout, this.startLabel, this.assemblyLabel, this.fontFamily);

  final FloorPlanLayout layout;
  final String startLabel;
  final String assemblyLabel;
  // CustomPainter text doesn't inherit DefaultTextStyle; pass the app font in.
  final String? fontFamily;

  Offset _offset(PlanPoint point, Size size) => Offset(point.x * size.width, point.y * size.height);

  bool _isZoneStop(int i) => layout.zones.any((z) => z.zone.id == layout.waypoints[i].waypoint.id);

  /// Where stop i is drawn. The start zone's marker sits on its tile edge, facing
  /// the next stop, so it doesn't cover the zone's name.
  Offset _anchor(int i, Size size) {
    final center = _offset(layout.waypoints[i].position, size);
    if (i != 0 || !_isZoneStop(i) || layout.waypoints.length < 2) return center;
    final next = _offset(layout.waypoints[1].position, size);
    final halfWidth = size.width * .095;
    return Offset(center.dx + (next.dx >= center.dx ? halfWidth : -halfWidth), center.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = HazardColors.surface);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      Paint()
        ..color = HazardColors.divider
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // A line is drawn before the tiles so any crossing remains visibly inside
    // the hazard tile, without implying that the points define real corridors.
    for (var i = 0; i + 1 < layout.waypoints.length; i++) {
      final a = _anchor(i, size);
      final b = _anchor(i + 1, size);
      final hazardous = layout.hazardousSegments.contains(i);
      final color = hazardous ? HazardColors.alarm : HazardColors.routeLine;
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      if (hazardous) {
        final length = (b - a).distance;
        if (length > 0) {
          final direction = (b - a) / length;
          for (var at = 0.0; at < length; at += 13) {
            canvas.drawLine(a + direction * at, a + direction * math.min(length, at + 7), paint);
          }
        }
      } else {
        canvas.drawLine(a, b, paint);
      }
      _arrow(canvas, a, b, color);
    }

    for (final zone in layout.zones) {
      final center = _offset(zone.position, size);
      final rect = Rect.fromCenter(
        center: center,
        width: size.width * .19,
        height: size.height * .13,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(9)),
        Paint()..color = zone.isHazard ? HazardColors.alarm : HazardColors.surface,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(9)),
        Paint()
          ..color = zone.isHazard ? HazardColors.alarm : HazardColors.divider
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      final textColor = zone.isHazard ? HazardColors.onHazard : HazardColors.text;
      if (zone.isHazard) {
        _icon(canvas, Icons.warning_rounded, Offset(center.dx, rect.top + 11),
            HazardColors.onHazard, 17);
      }
      _text(
        canvas,
        zone.zone.label,
        Rect.fromLTWH(rect.left + 3, zone.isHazard ? rect.top + 18 : rect.top + 4,
            rect.width - 6, rect.height - (zone.isHazard ? 19 : 8)),
        color: textColor,
        fontSize: 14,
      );
    }

    for (var i = 0; i < layout.waypoints.length; i++) {
      final placed = layout.waypoints[i];
      final point = _anchor(i, size);
      final kind = placed.waypoint.kind.toLowerCase();
      final isAssembly = kind.contains('assembly') ||
          (i == layout.waypoints.length - 1 && !layout.zones.any((z) => z.zone.id == placed.waypoint.id));
      if (i == 0) {
        canvas.drawCircle(point, 12, Paint()..color = HazardColors.start);
        canvas.drawCircle(point, 5, Paint()..color = HazardColors.onHazard);
      } else if (kind.contains('stair')) {
        final path = Path()
          ..moveTo(point.dx, point.dy - 12)
          ..lineTo(point.dx + 12, point.dy + 10)
          ..lineTo(point.dx - 12, point.dy + 10)
          ..close();
        canvas.drawPath(path, Paint()..color = HazardColors.routeLine);
      } else if (kind.contains('exit')) {
        canvas.drawRect(Rect.fromCenter(center: point, width: 21, height: 21),
            Paint()..color = HazardColors.routeLine);
        canvas.drawCircle(point, 3, Paint()..color = HazardColors.onHazard);
      } else if (isAssembly) {
        final path = Path()
          ..moveTo(point.dx, point.dy - 13)
          ..lineTo(point.dx + 13, point.dy)
          ..lineTo(point.dx, point.dy + 13)
          ..lineTo(point.dx - 13, point.dy)
          ..close();
        canvas.drawPath(path, Paint()..color = HazardColors.routeLine);
      } else {
        canvas.drawCircle(point, 8, Paint()..color = HazardColors.routeLine);
      }

      final zoneStop = _isZoneStop(i);
      if (!zoneStop || i == 0) {
        final label = i == 0
            ? startLabel
            : placed.waypoint.label.trim().isNotEmpty
                ? placed.waypoint.label
                : isAssembly ? assemblyLabel : '';
        if (label.isNotEmpty) {
          // Up to two lines above the marker, on a white backing so the route
          // line never runs through the text.
          const labelWidth = 160.0;
          const labelHeight = 38.0;
          final labelRect = Rect.fromLTWH(
            math.max(4.0, math.min(size.width - labelWidth - 4, point.dx - labelWidth / 2)),
            math.max(4.0, point.dy - 16 - labelHeight),
            labelWidth,
            labelHeight,
          );
          _text(canvas, label, labelRect,
              color: HazardColors.text, fontSize: 14, maxLines: 2, backing: true,
              alignBottom: true);
        }
      }
    }
  }

  void _arrow(Canvas canvas, Offset a, Offset b, Color color) {
    final delta = b - a;
    if (delta.distance < 28) return;
    final direction = delta / delta.distance;
    final center = Offset.lerp(a, b, .52)!;
    final normal = Offset(-direction.dy, direction.dx);
    final tip = center + direction * 8;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((center - direction * 7 + normal * 6).dx,
          (center - direction * 7 + normal * 6).dy)
      ..lineTo((center - direction * 7 - normal * 6).dx,
          (center - direction * 7 - normal * 6).dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _icon(Canvas canvas, IconData icon, Offset center, Color color, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  void _text(Canvas canvas, String value, Rect rect,
      {required Color color,
      required double fontSize,
      int maxLines = 1,
      bool backing = false,
      bool alignBottom = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
            color: color, fontSize: fontSize, fontWeight: FontWeight.w600, fontFamily: fontFamily),
      ),
      maxLines: maxLines,
      ellipsis: '…',
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    final origin = Offset(rect.left + (rect.width - painter.width) / 2,
        alignBottom ? rect.bottom - painter.height : rect.top + (rect.height - painter.height) / 2);
    if (backing) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            (origin & Size(painter.width, painter.height)).inflate(3), const Radius.circular(4)),
        Paint()..color = HazardColors.surface.withValues(alpha: .92),
      );
    }
    painter.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(covariant _FloorPlanPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.startLabel != startLabel ||
      oldDelegate.assemblyLabel != assemblyLabel ||
      oldDelegate.fontFamily != fontFamily;
}
