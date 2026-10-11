/// The alarm screen's small floor plan, kept simple for someone who is scared:
/// the resident's own apartment with its rooms ("Tu"), every other apartment as
/// one block with its name, the common areas that matter for getting out, and
/// an exit block at the end of the way out. Red marks only the danger: the
/// block it is in, and the room inside it. Pure: placed from the zones' centre
/// points like the home sketch (relative, not to scale).
library;

import 'package:flutter/foundation.dart';

import '../models/evacuation.dart';
import '../models/incident.dart';
import '../models/zone_info.dart';
import 'floor_plan.dart';
import 'relative_location.dart';

enum PlanBlockKind { home, apartment, common, exit }

/// A rectangle of grid cells.
typedef PlanArea = ({int col, int row, int cols, int rows});

/// A room drawn inside a block, at its own cell.
@immutable
class PlanRoom {
  const PlanRoom({required this.zoneId, required this.label, required this.kind, required this.cell, this.danger = false});
  final String zoneId;
  final String label;

  /// Room kind from the zone list (kitchen, bathroom, ...).
  final String? kind;
  final GridCell cell;
  final bool danger;
}

@immutable
class PlanBlock {
  const PlanBlock({
    required this.id,
    required this.label,
    required this.kind,
    required this.area,
    this.rooms = const [],
    this.danger = false,
    this.onRoute = false,
  });

  /// Unit id for apartments, zone id for a common area, `exit` for the exit.
  final String id;

  /// "Ap. 13", "Hol scară"; the exit's waypoint name.
  final String label;
  final PlanBlockKind kind;
  final PlanArea area;

  /// The rooms drawn inside: every room of a home, only the danger room(s) of
  /// any other apartment.
  final List<PlanRoom> rooms;

  /// The danger is in this block: outlined red (a common area: filled red).
  final bool danger;

  /// A common area the way out goes through.
  final bool onRoute;
}

@immutable
class EscapePlan {
  const EscapePlan({required this.cols, required this.rows, required this.blocks, required this.path, this.floorLabel});
  static const empty = EscapePlan(cols: 0, rows: 0, blocks: [], path: []);

  final int cols;
  final int rows;
  final List<PlanBlock> blocks;

  /// Block ids of the way out, in order: the resident's home, the common areas
  /// of the route, the exit.
  final List<String> path;
  final String? floorLabel;

  bool get isEmpty => blocks.isEmpty;

  PlanBlock? block(String id) => blocks.where((b) => b.id == id).firstOrNull;
}

const _escapeKinds = {'hallway', 'stairwell', 'exit'};

bool _sameFloor(ZoneInfo a, {String? floorId, String? floorLabel}) =>
    floorId != null ? a.floorId == floorId : floorLabel != null && a.floorLabel == floorLabel;

/// The zones of the floor the plan shows: the resident's (they get out from
/// there), else the danger's. Neither known: the danger's zones and the
/// resident's rooms.
List<ZoneInfo> escapeFloorZones(Incident incident, List<ZoneInfo> zones, ResidentHome home) {
  final hazard = incident.hazardZoneIds;
  final mine = zones.where((z) => !z.isCommon && home.contains(z.unitId)).firstOrNull;
  final anchor = mine ?? zones.where((z) => hazard.contains(z.id)).firstOrNull;
  if (anchor == null) return const [];
  if (anchor.floorId == null && anchor.floorLabel == null) {
    return [
      for (final z in zones)
        if (hazard.contains(z.id) || (!z.isCommon && home.contains(z.unitId))) z,
    ];
  }
  return [
    for (final z in zones)
      if (_sameFloor(z, floorId: anchor.floorId, floorLabel: anchor.floorLabel)) z,
  ];
}

/// The plan for [incident] seen by a resident of [home], with the way out of
/// [route] (null: no way out drawn). Zones without a position are left out.
EscapePlan escapePlan({
  required Incident incident,
  required List<ZoneInfo> zones,
  required ResidentHome home,
  EvacuationRoute? route,
}) {
  final hazard = incident.hazardZoneIds;
  final routeIds = route?.path.toSet() ?? const <String>{};
  final floor = escapeFloorZones(incident, zones, home);
  // Common areas only where they help to get out, or hold the danger.
  final shown = [
    for (final z in floor)
      if (z.hasPosition &&
          (!z.isCommon || hazard.contains(z.id) || routeIds.contains(z.id) || _escapeKinds.contains(z.kind)))
        z,
  ];
  if (shown.isEmpty) return EscapePlan.empty;
  final cells = gridLayout([for (final z in shown) (id: z.id, x: z.posX!, y: z.posY!)]);
  var cols = cells.values.map((c) => c.col).reduce((a, b) => a > b ? a : b) + 1;
  var rows = cells.values.map((c) => c.row).reduce((a, b) => a > b ? a : b) + 1;

  final blocks = <PlanBlock>[];
  // Apartments: the cells of their rooms make one block.
  final byUnit = <String, List<ZoneInfo>>{};
  for (final z in shown) {
    if (!z.isCommon) (byUnit[z.unitId] ??= []).add(z);
  }
  for (final MapEntry(key: unitId, value: rooms) in byUnit.entries) {
    final own = home.contains(unitId);
    final at = [for (final r in rooms) cells[r.id]!];
    final col = at.map((c) => c.col).reduce((a, b) => a < b ? a : b);
    final row = at.map((c) => c.row).reduce((a, b) => a < b ? a : b);
    final danger = rooms.any((r) => hazard.contains(r.id));
    blocks.add(PlanBlock(
      id: unitId,
      label: rooms.first.unitLabel ?? home.unit(unitId)?.label ?? rooms.first.label,
      kind: own ? PlanBlockKind.home : PlanBlockKind.apartment,
      area: (
        col: col,
        row: row,
        cols: at.map((c) => c.col).reduce((a, b) => a > b ? a : b) - col + 1,
        rows: at.map((c) => c.row).reduce((a, b) => a > b ? a : b) - row + 1,
      ),
      danger: danger,
      rooms: [
        for (final r in rooms)
          if (own || hazard.contains(r.id))
            PlanRoom(zoneId: r.id, label: r.label, kind: r.kind, cell: cells[r.id]!, danger: hazard.contains(r.id)),
      ],
    ));
  }
  for (final z in shown.where((z) => z.isCommon)) {
    final c = cells[z.id]!;
    blocks.add(PlanBlock(
      id: z.id,
      label: z.label,
      kind: PlanBlockKind.common,
      area: (col: c.col, row: c.row, cols: 1, rows: 1),
      danger: hazard.contains(z.id),
      onRoute: routeIds.contains(z.id),
    ));
  }

  // The exit, next to the last common area of the way out that is on the plan.
  final path = <String>[
    if (blocks.where((b) => b.kind == PlanBlockKind.home).firstOrNull case final PlanBlock h) h.id,
  ];
  if (route != null) {
    final onPlan = [
      for (final id in route.path)
        if (blocks.any((b) => b.id == id && b.kind == PlanBlockKind.common)) id,
    ];
    path.addAll(onPlan);
    bool taken(int c, int r) => blocks.any((b) =>
        c >= b.area.col && c < b.area.col + b.area.cols && r >= b.area.row && r < b.area.row + b.area.rows);
    final anchor = onPlan.isEmpty ? null : blocks.firstWhere((b) => b.id == onPlan.last).area;
    GridCell? spot;
    if (anchor != null) {
      for (final (dc, dr) in const [(0, 1), (1, 0), (-1, 0), (0, -1)]) {
        final c = anchor.col + dc;
        final r = anchor.row + dr;
        if (c >= 0 && r >= 0 && c < cols && r < rows && !taken(c, r)) {
          spot = (col: c, row: r);
          break;
        }
      }
    }
    spot ??= (col: anchor?.col ?? 0, row: rows);
    if (spot.row >= rows) rows = spot.row + 1;
    if (spot.col >= cols) cols = spot.col + 1;
    final exit = route.waypoints.where((w) => w.kind == 'exit').firstOrNull ?? route.waypoints.lastOrNull;
    blocks.add(PlanBlock(
      id: 'exit',
      label: exit?.label ?? '',
      kind: PlanBlockKind.exit,
      area: (col: spot.col, row: spot.row, cols: 1, rows: 1),
    ));
    path.add('exit');
  }
  final floorLabel = floor.map((z) => z.floorLabel).nonNulls.firstOrNull;
  return EscapePlan(cols: cols, rows: rows, blocks: blocks, path: path, floorLabel: floorLabel);
}
