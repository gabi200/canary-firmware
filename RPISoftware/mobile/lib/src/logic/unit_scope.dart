/// The apartment / room picker over the sensor lists. Staff see the whole
/// building, so they pick a flat (then one of its rooms); residents with two or
/// more homes pick a home. Pure: built from the rooms a screen lists and the
/// building's zone list, whichever says which unit a zone belongs to.
library;

import 'package:flutter/foundation.dart';

import '../models/summary.dart';
import '../models/zone_info.dart';
import '../state/dashboard_providers.dart' show prettyZone;

/// What the user picked. Nothing picked yet ([none]): the first apartment.
@immutable
class ScopeChoice {
  const ScopeChoice({this.unitId, this.zoneId}) : building = false;

  /// "Toată clădirea".
  const ScopeChoice.wholeBuilding()
      : unitId = null,
        zoneId = null,
        building = true;

  static const none = ScopeChoice();

  /// The picked flat / common area.
  final String? unitId;

  /// One room of [unitId], or null for all its rooms.
  final String? zoneId;
  final bool building;

  Map<String, Object?> toJson() => building ? {'all': true} : {'unit': unitId, 'zone': zoneId};

  factory ScopeChoice.fromJson(Object? j) {
    if (j is! Map) return none;
    if (j['all'] == true) return const ScopeChoice.wholeBuilding();
    final unit = j['unit'];
    final zone = j['zone'];
    if (unit is! String || unit.isEmpty) return none;
    return ScopeChoice(unitId: unit, zoneId: zone is String && zone.isNotEmpty ? zone : null);
  }

  @override
  bool operator ==(Object other) =>
      other is ScopeChoice && other.unitId == unitId && other.zoneId == zoneId && other.building == building;

  @override
  int get hashCode => Object.hash(unitId, zoneId, building);
}

/// A room of a list: the zone, the sensors the screen lists for it, its plain
/// name ("Bucătărie") and its unit's name ("Ap. 12"), when known.
@immutable
class ScopeRoom {
  const ScopeRoom({required this.zone, required this.nodes, required this.label, this.unitLabel});
  final ZoneSummary zone;
  final List<NodeAnalysis> nodes;
  final String label;
  final String? unitLabel;

  String get zoneId => zone.zoneId;
  String get status => worstStatus(nodes.map((n) => n.status));

  /// "Bucătărie · Ap. 12": the name outside its unit, where "Bucătărie" repeats.
  String get fullLabel {
    final unit = unitLabel;
    return unit == null || unit == label ? label : '$label · $unit';
  }
}

/// A flat or common area with the rooms the list shows for it.
@immutable
class ScopeUnit {
  const ScopeUnit({required this.id, required this.label, required this.common, required this.rooms});
  final String id;
  final String label;

  /// Shared area of the building ("Spații comune").
  final bool common;
  final List<ScopeRoom> rooms;

  int get sensorCount => rooms.fold(0, (n, r) => n + r.nodes.length);
  String get status => worstStatus(rooms.expand((r) => r.nodes).map((n) => n.status));
}

/// One list's picker and what it shows.
@immutable
class SensorScope {
  const SensorScope({required this.rooms, required this.staff, this.units = const [], this.unit, this.room});

  /// Every room of the list, in summary order.
  final List<ScopeRoom> rooms;

  /// Staff (whole building): the rooms row and "Toată clădirea".
  final bool staff;

  /// The picker's units: apartments, then common areas. Empty: no picker.
  final List<ScopeUnit> units;

  /// The picked unit; null shows every room (whole building, or no picker).
  final ScopeUnit? unit;

  /// The picked room of [unit]; null shows all its rooms.
  final ScopeRoom? room;

  bool get hasPicker => units.isNotEmpty;

  /// The second row: staff with a unit of several rooms picked.
  bool get showsRooms => staff && (unit?.rooms.length ?? 0) > 1;

  /// The rooms the list shows, in summary order.
  List<ScopeRoom> get shown {
    final r = room;
    return r != null ? [r] : unit?.rooms ?? rooms;
  }

  /// Sensors and worst status of the whole list ("Toată clădirea").
  int get sensorCount => rooms.fold(0, (n, r) => n + r.nodes.length);
  String get status => worstStatus(rooms.expand((r) => r.nodes).map((n) => n.status));

  /// What is picked, for "Testează toate alarmele · Ap. 12"; null: everything.
  String? get label => room?.fullLabel ?? unit?.label;

  /// The list spans units, so a plain "Bucătărie" would be ambiguous.
  bool get _spansUnits => unit == null && (staff || hasPicker);

  /// A room's heading in the list: plain inside a picked unit, with its unit
  /// otherwise ("Bucătărie · Ap. 12").
  String labelOf(ScopeRoom r) => _spansUnits ? r.fullLabel : r.label;

  /// A room's name away from the list (sensor sheet): with its unit whenever
  /// the user may see more than one unit.
  String sheetLabelOf(ScopeRoom r) => staff || hasPicker ? r.fullLabel : r.label;

  ScopeRoom? roomOf(String? zoneId) => rooms.where((r) => r.zoneId == zoneId).firstOrNull;
}

/// The picker over [listed] (each room with the sensors the screen shows for
/// it). A zone's unit comes from the summary or, failing that, [infos]; zones
/// without one show only with everything. Staff get a picker with two or more
/// units, residents with two or more homes. A stale [choice] (unit gone)
/// falls back to the first apartment.
SensorScope resolveScope(
  Iterable<(ZoneSummary, List<NodeAnalysis>)> listed,
  Map<String, ZoneInfo> infos,
  ScopeChoice choice, {
  required bool staff,
}) {
  final rooms = <ScopeRoom>[];
  final byUnit = <String, List<ScopeRoom>>{};
  final unitLabels = <String, String>{};
  final common = <String, bool>{};
  for (final (zone, nodes) in listed) {
    final info = infos[zone.zoneId];
    final infoUnit = info?.unitId;
    final unitId = zone.unitId ?? (infoUnit == null || infoUnit.isEmpty ? null : infoUnit);
    final unitLabel = unitId == null ? null : zone.unitLabel ?? info?.unitLabel ?? prettyZone(null, unitId);
    final label = zone.zoneLabel.isNotEmpty ? zone.zoneLabel : info?.label ?? prettyZone(null, zone.zoneId);
    final room = ScopeRoom(zone: zone, nodes: nodes, label: label, unitLabel: unitLabel);
    rooms.add(room);
    if (unitId == null) continue;
    (byUnit[unitId] ??= []).add(room);
    unitLabels.putIfAbsent(unitId, () => unitLabel!);
    common[unitId] = (common[unitId] ?? false) || info?.unitKind == 'common' || unitId.toLowerCase().contains('common');
  }
  final units = [
    for (final MapEntry(key: id, value: unitRooms) in byUnit.entries)
      ScopeUnit(id: id, label: unitLabels[id]!, common: common[id]!, rooms: unitRooms),
  ]..sort((a, b) {
      if (a.common != b.common) return a.common ? 1 : -1;
      final byLabel = compareNatural(a.label, b.label);
      return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
    });
  final homes = units.where((u) => !u.common).length;
  if (staff ? units.length < 2 : homes < 2) return SensorScope(rooms: rooms, staff: staff);

  final unit = choice.building
      ? null
      : units.where((u) => u.id == choice.unitId).firstOrNull ??
          units.firstWhere((u) => !u.common, orElse: () => units.first);
  // Residents have no rooms row, so a room choice never narrows their list.
  final room = staff ? unit?.rooms.where((r) => r.zoneId == choice.zoneId).firstOrNull : null;
  return SensorScope(rooms: rooms, staff: staff, units: units, unit: unit, room: room);
}

/// The worst of [statuses], ranked like the hub: danger, attention, ok;
/// unknown only when nothing says otherwise.
String worstStatus(Iterable<String> statuses) {
  const rank = {'ok': 1, 'attention': 2, 'danger': 3};
  var worst = 'unknown';
  for (final s in statuses) {
    if ((rank[s] ?? 0) > (rank[worst] ?? 0)) worst = s;
  }
  return worst;
}

/// "Ap. 2" < "Ap. 12" < "Ap. 13": runs of digits compare as numbers, the rest
/// case-insensitively.
int compareNatural(String a, String b) {
  final chunk = RegExp(r'\d+|\D+');
  final x = chunk.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final y = chunk.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  final digits = RegExp(r'^\d');
  for (var i = 0; i < x.length && i < y.length; i++) {
    final p = x[i];
    final q = y[i];
    int c;
    if (digits.hasMatch(p) && digits.hasMatch(q)) {
      final pn = p.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final qn = q.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      c = pn.length != qn.length ? pn.length.compareTo(qn.length) : pn.compareTo(qn);
    } else {
      c = p.compareTo(q);
    }
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}
