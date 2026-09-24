import 'package:flutter/material.dart';

import '../../models/evacuation.dart';

/// Lightweight schematic of an evacuation route: ordered waypoints connected by
/// arrows, ending at the assembly point. A real build renders this over a floor
/// plan (CustomPainter on an SVG/raster layer, ARCHITECTURE.md section C/D); the
/// MVP draws the route topology so the resident sees the path and exit ordering.
class EvacuationMap extends StatelessWidget {
  const EvacuationMap({super.key, required this.route, required this.assembly});
  final EvacuationRoute route;
  final AssemblyPoint? assembly;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF1F3F4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black12),
        ),
        child: CustomPaint(
          painter: _RoutePainter(route.path, assembly?.label ?? route.toAssemblyPointId),
        ),
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter(this.path, this.assemblyLabel);
  final List<String> path;
  final String assemblyLabel;

  @override
  void paint(Canvas canvas, Size size) {
    if (path.isEmpty) return;
    final line = Paint()
      ..color = const Color(0xFFB71C1C)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    final dot = Paint()..color = const Color(0xFFB71C1C);
    final endDot = Paint()..color = const Color(0xFF2E7D32);

    final n = path.length;
    final margin = 28.0;
    final usableW = size.width - margin * 2;
    final y = size.height / 2;
    final dx = n > 1 ? usableW / (n - 1) : 0.0;

    final points = <Offset>[for (var i = 0; i < n; i++) Offset(margin + dx * i, y)];

    // connecting line
    for (var i = 0; i < n - 1; i++) {
      canvas.drawLine(points[i], points[i + 1], line);
    }

    final tp = TextPainter(textDirection: TextDirection.ltr, textAlign: TextAlign.center);
    for (var i = 0; i < n; i++) {
      final isEnd = i == n - 1;
      canvas.drawCircle(points[i], isEnd ? 9 : 6, isEnd ? endDot : dot);
      final label = isEnd ? assemblyLabel : path[i];
      tp.text = TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.black87,
          fontSize: 11,
          fontWeight: isEnd ? FontWeight.w700 : FontWeight.w500,
        ),
      );
      tp.layout(maxWidth: dx > 0 ? dx + 24 : size.width);
      tp.paint(canvas, Offset(points[i].dx - tp.width / 2, y + (i.isEven ? 14 : -28)));
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePainter old) =>
      old.path != path || old.assemblyLabel != assemblyLabel;
}
