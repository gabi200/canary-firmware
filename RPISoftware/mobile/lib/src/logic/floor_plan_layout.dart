import 'dart:math' as math;

import '../models/evacuation.dart';
import '../models/zone.dart';

/// Coordinates in the schematic's unit square. They are not building geometry.
class PlanPoint {
  const PlanPoint(this.x, this.y);
  final double x;
  final double y;
}

class PlacedZone {
  const PlacedZone(this.zone, this.position, {required this.isHazard});
  final ZoneInfo zone;
  final PlanPoint position;
  final bool isHazard;
}

class PlacedWaypoint {
  const PlacedWaypoint(this.waypoint, this.position, {required this.isHazard});
  final Waypoint waypoint;
  final PlanPoint position;
  final bool isHazard;
}

class FloorPlanLayout {
  const FloorPlanLayout({
    required this.zones,
    required this.waypoints,
    required this.hazardousSegments,
    required this.routePassesHazard,
  });

  final List<PlacedZone> zones;
  final List<PlacedWaypoint> waypoints;
  /// Segment index i connects waypoints i and i + 1.
  final Set<int> hazardousSegments;
  final bool routePassesHazard;
}

const _laneX = .84;

/// Pure placement: no map, wall, corridor, or travel-distance claim is made.
FloorPlanLayout buildFloorPlanLayout(
  List<ZoneInfo> allZones,
  List<Waypoint> route,
  Set<String> hazardZoneIds,
) {
  final byId = {for (final zone in allZones) zone.id: zone};
  String? floorId;
  for (final stop in route) {
    final zone = byId[stop.id];
    if (zone != null) {
      floorId = zone.floorId;
      break;
    }
  }
  final floorZones = floorId == null
      ? allZones
      : allZones.where((zone) => zone.floorId == floorId).toList();

  if (floorZones.isEmpty) {
    final placed = <PlacedWaypoint>[
      for (var i = 0; i < route.length; i++)
        PlacedWaypoint(
          route[i],
          PlanPoint(.5, route.length == 1 ? .5 : .16 + .68 * i / (route.length - 1)),
          isHazard: hazardZoneIds.contains(route[i].id),
        ),
    ];
    final segments = <int>{
      for (var i = 0; i + 1 < placed.length; i++)
        if (placed[i].isHazard || placed[i + 1].isHazard) i,
    };
    return FloorPlanLayout(
      zones: const [],
      waypoints: placed,
      hazardousSegments: segments,
      routePassesHazard: placed.any((stop) => stop.isHazard),
    );
  }

  final minX = floorZones.map((zone) => zone.x).reduce(math.min);
  final maxX = floorZones.map((zone) => zone.x).reduce(math.max);
  final minY = floorZones.map((zone) => zone.y).reduce(math.min);
  final maxY = floorZones.map((zone) => zone.y).reduce(math.max);
  // Zones fill the left part, below the "not to scale" badge; the right-hand
  // lane (x >= _laneX - margin) is reserved for stops without coordinates.
  PlanPoint pointFor(ZoneInfo zone) => PlanPoint(
    maxX == minX ? .30 : .11 + .38 * (zone.x - minX) / (maxX - minX),
    maxY == minY ? .58 : .30 + .56 * (zone.y - minY) / (maxY - minY),
  );

  final placedZones = [
    for (final zone in floorZones)
      PlacedZone(zone, pointFor(zone), isHazard: hazardZoneIds.contains(zone.id)),
  ];
  final placed = <PlacedWaypoint>[];
  final laneStops = route
      .where((stop) => !(byId[stop.id]?.floorId == floorId && byId.containsKey(stop.id)))
      .length;
  var laneIndex = 0;
  for (final stop in route) {
    final zone = byId[stop.id];
    if (zone != null && zone.floorId == floorId) {
      placed.add(PlacedWaypoint(stop, pointFor(zone), isHazard: hazardZoneIds.contains(stop.id)));
      continue;
    }
    // Stops without coordinates (stairs, exits, the assembly point) stack top
    // to bottom in route order in the right-hand lane, clear of every zone tile.
    final y = laneStops == 1 ? .58 : .34 + .54 * laneIndex / (laneStops - 1);
    laneIndex++;
    placed.add(PlacedWaypoint(
      stop,
      PlanPoint(_laneX, y),
      isHazard: hazardZoneIds.contains(stop.id),
    ));
  }

  final hazardousSegments = <int>{};
  for (var i = 0; i + 1 < placed.length; i++) {
    final a = placed[i];
    final b = placed[i + 1];
    if (a.isHazard || b.isHazard || placedZones.any((zone) =>
        zone.isHazard && _segmentTouchesTile(a.position, b.position, zone.position))) {
      hazardousSegments.add(i);
    }
  }
  return FloorPlanLayout(
    zones: placedZones,
    waypoints: placed,
    hazardousSegments: hazardousSegments,
    routePassesHazard: placed.any((stop) => stop.isHazard) || hazardousSegments.isNotEmpty,
  );
}

// The tile footprint is shared with the painter. Clipping a segment against it
// catches a route that passes through a hazard even without a stop there.
bool _segmentTouchesTile(PlanPoint a, PlanPoint b, PlanPoint center) {
  const halfWidth = .095;
  const halfHeight = .065;
  var start = 0.0;
  var end = 1.0;
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  for (final bound in <(double, double)>[
    (-dx, a.x - (center.x - halfWidth)),
    (dx, center.x + halfWidth - a.x),
    (-dy, a.y - (center.y - halfHeight)),
    (dy, center.y + halfHeight - a.y),
  ]) {
    final (p, q) = bound;
    if (p == 0) {
      if (q < 0) return false;
    } else {
      final t = q / p;
      if (p < 0) {
        start = math.max(start, t);
      } else {
        end = math.min(end, t);
      }
      if (start > end) return false;
    }
  }
  return true;
}
