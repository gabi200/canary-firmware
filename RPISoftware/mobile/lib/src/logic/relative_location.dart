/// Where a hazard is from the resident's point of view: in their own home
/// (which room), elsewhere on their floor (which apartment / common area), on
/// another floor (which floor) or in a common area. Pure: built from the
/// incident's zones, the building's zone list and the resident's own units.
library;

import 'package:flutter/foundation.dart';

import '../models/check_in.dart';
import '../models/incident.dart';
import '../models/zone_info.dart';
import '../state/dashboard_providers.dart' show prettyZone;

/// One of the resident's homes: the flat, its name and its floor.
@immutable
class HomeUnit {
  const HomeUnit({required this.id, required this.label, this.floorId, this.floorLabel});
  final String id;

  /// "Ap. 12"
  final String label;
  final String? floorId;

  /// "Etaj 3" (building data, shown as sent).
  final String? floorLabel;

  /// "Ap. 12 · Etaj 3"
  String get title => floorLabel == null ? label : '$label · $floorLabel';
}

/// The resident's homes (usually one); empty when not known yet.
@immutable
class ResidentHome {
  const ResidentHome(this.units);
  static const none = ResidentHome([]);

  final List<HomeUnit> units;

  bool contains(String? unitId) => units.any((u) => u.id == unitId);

  HomeUnit? unit(String? unitId) => units.where((u) => u.id == unitId).firstOrNull;

  /// The header: "Ap. 12 · Etaj 3"; several homes: "Ap. 12, Ap. 20"; null
  /// while unknown.
  String? get title => switch (units.length) {
        0 => null,
        1 => units.single.title,
        _ => units.map((u) => u.label).join(', '),
      };

  /// Whether [zone] is on a floor with one of the homes; null when the floors
  /// can't be compared (no floor on either side).
  bool? sharesFloor(ZoneInfo zone) {
    bool? result;
    for (final u in units) {
      final same = zone.floorId != null && u.floorId != null
          ? zone.floorId == u.floorId
          : zone.floorLabel != null && u.floorLabel != null
              ? zone.floorLabel == u.floorLabel
              : null;
      if (same == true) return true;
      if (same == false) result = false;
    }
    return result;
  }
}

/// The resident's homes from their own units ([own]: id, label and floor as
/// `GET /me` lists them). A missing label or floor comes from the unit's zones.
ResidentHome residentHome(
  Iterable<({String id, String? label, String? floorLabel})> own,
  Iterable<ZoneInfo> zones,
) {
  final units = <HomeUnit>[];
  for (final u in own) {
    if (units.any((h) => h.id == u.id)) continue;
    final zone = zones.where((z) => z.unitId == u.id).firstOrNull;
    units.add(HomeUnit(
      id: u.id,
      label: u.label ?? zone?.unitLabel ?? prettyZone(null, u.id),
      floorId: zone?.floorId,
      floorLabel: u.floorLabel ?? zone?.floorLabel,
    ));
  }
  return ResidentHome(units);
}

enum HazardPlace {
  /// In one of the resident's homes; [HazardWhere.detail] is the room.
  home,

  /// Another apartment on the resident's floor; detail: the apartment.
  myFloor,

  /// A common area on the resident's floor; detail: the area.
  myFloorCommon,

  /// Another floor; detail: the floor and the apartment / area there.
  otherFloor,

  /// A common area whose floor can't be compared; detail: the area.
  commonArea,

  /// An apartment whose floor can't be compared; detail: the apartment.
  building,

  /// The zones aren't known (yet); detail is null.
  unknown,
}

/// Where the danger is, relative to the resident, as one line of text
/// (see `AppLocalizations.hazardWhereText`).
@immutable
class HazardWhere {
  const HazardWhere(this.place, {this.zoneId, this.detail});
  final HazardPlace place;

  /// The zone the line is about (the source, or the room of the home it reached).
  final String? zoneId;

  /// The room / apartment / floor named in the line (building data).
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is HazardWhere && other.place == place && other.zoneId == zoneId && other.detail == detail;

  @override
  int get hashCode => Object.hash(place, zoneId, detail);

  @override
  String toString() => 'HazardWhere($place, $zoneId, $detail)';
}

/// The incident's zones in order (the source first), without duplicates.
List<String> _incidentZoneIds(Incident incident) => {
      if (incident.primaryZoneId != null) incident.primaryZoneId!,
      ...incident.affectedZoneIds,
    }.toList();

String _unitName(ZoneInfo z) =>
    z.unitLabel ?? (z.unitId.isEmpty ? z.label : prettyZone(null, z.unitId));

/// Where [incident] is for a resident of [home], given the building's [zones]
/// by id. Danger that reaches the resident's home wins, even when it started
/// next door; otherwise the source zone decides.
HazardWhere hazardWhere(Incident incident, Map<String, ZoneInfo> zones, ResidentHome home) {
  final known = [
    for (final id in _incidentZoneIds(incident))
      if (zones[id] case final ZoneInfo z) z,
  ];
  final mine = known.where((z) => !z.isCommon && home.contains(z.unitId)).firstOrNull;
  if (mine != null) {
    // With several homes, say which one.
    final detail = home.units.length > 1 ? '${mine.label} · ${home.unit(mine.unitId)!.label}' : mine.label;
    return HazardWhere(HazardPlace.home, zoneId: mine.id, detail: detail);
  }
  final source = known.firstOrNull;
  if (source == null) return const HazardWhere(HazardPlace.unknown);
  final what = source.isCommon ? source.label : _unitName(source);
  switch (home.sharesFloor(source)) {
    case true:
      return HazardWhere(source.isCommon ? HazardPlace.myFloorCommon : HazardPlace.myFloor,
          zoneId: source.id, detail: what);
    case false:
      return HazardWhere(HazardPlace.otherFloor,
          zoneId: source.id, detail: [if (source.floorLabel != null) source.floorLabel!, what].join(' · '));
    case null:
      return source.isCommon
          ? HazardWhere(HazardPlace.commonArea,
              zoneId: source.id, detail: [what, if (source.floorLabel != null) source.floorLabel!].join(' · '))
          : HazardWhere(HazardPlace.building, zoneId: source.id, detail: what);
  }
}

/// One room of the incident: is it where it started, and is it the resident's?
typedef AffectedRoom = ({ZoneInfo zone, bool source, bool mine});

/// The incident's rooms the building's [zones] know, the source first.
List<AffectedRoom> affectedRooms(Incident incident, Map<String, ZoneInfo> zones, ResidentHome home) => [
      for (final id in _incidentZoneIds(incident))
        if (zones[id] case final ZoneInfo z)
          (zone: z, source: id == incident.primaryZoneId, mine: !z.isCommon && home.contains(z.unitId)),
    ];

/// What the resident should do next, from their answer to "Unde ești acum?".
enum WhereAdvice {
  /// Home, and the danger is in it: leave now, close the door.
  leaveHomeNow,

  /// Home, evacuation ordered: phone, keys, close the door, follow the route.
  leaveHome,

  /// Home, danger elsewhere and no evacuation yet: get ready to leave.
  getReady,

  /// Elsewhere in the building: nearest stairs, don't go back for things.
  leaveBuilding,

  /// Outside: stay out, go to the assembly point.
  stayOut,
}

WhereAdvice whereAdvice(ResidentLocation where, HazardPlace place, {required bool evacuation}) => switch (where) {
      ResidentLocation.outside => WhereAdvice.stayOut,
      ResidentLocation.building => WhereAdvice.leaveBuilding,
      ResidentLocation.home when place == HazardPlace.home => WhereAdvice.leaveHomeNow,
      ResidentLocation.home when evacuation => WhereAdvice.leaveHome,
      ResidentLocation.home => WhereAdvice.getReady,
    };
