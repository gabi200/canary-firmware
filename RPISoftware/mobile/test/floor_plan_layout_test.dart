import 'package:canary_resident/src/logic/floor_plan_layout.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/models/zone.dart';
import 'package:flutter_test/flutter_test.dart';

const zones = [
  ZoneInfo(id: 'zone_kitchen', floorId: 'flr_03', unitId: 'unit_0312', label: 'Kitchen', kind: 'room', x: 2, y: 2),
  ZoneInfo(id: 'zone_bedroom', floorId: 'flr_03', unitId: 'unit_0312', label: 'Bedroom', kind: 'room', x: 8, y: 2),
  ZoneInfo(id: 'zone_hallway', floorId: 'flr_03', unitId: null, label: 'Hallway', kind: 'hallway', x: 5, y: 5),
  ZoneInfo(id: 'zone_boiler', floorId: 'flr_03', unitId: null, label: 'Boiler', kind: 'room', x: 2, y: 8),
  ZoneInfo(id: 'zone_other', floorId: 'flr_02', unitId: null, label: 'Other floor', kind: 'room', x: 5, y: 5),
];

const route = [
  Waypoint(id: 'zone_hallway', label: 'Hallway', kind: 'zone'),
  Waypoint(id: 'stairwell_main', label: 'Main stairs', kind: 'stairwell'),
  Waypoint(id: 'exit_front', label: 'Front exit', kind: 'exit'),
  Waypoint(id: 'ap_main', label: 'Assembly point', kind: 'assembly'),
];

void main() {
  test('seed route keeps order, floor, bounds, and stops off zone tiles', () {
    final layout = buildFloorPlanLayout(zones, route, {'zone_kitchen'});
    expect(layout.zones.map((z) => z.zone.id), isNot(contains('zone_other')));
    expect(layout.zones.length, 4);
    expect(layout.waypoints.map((w) => w.waypoint.id), route.map((w) => w.id));
    for (final point in [
      ...layout.zones.map((z) => z.position),
      ...layout.waypoints.map((w) => w.position),
    ]) {
      expect(point.x, inInclusiveRange(0, 1));
      expect(point.y, inInclusiveRange(0, 1));
    }
    for (final stop in layout.waypoints.skip(1)) {
      for (final zone in layout.zones) {
        expect(
          (stop.position.x - zone.position.x).abs() >= .095 ||
              (stop.position.y - zone.position.y).abs() >= .065,
          isTrue,
        );
      }
    }
    expect(layout.zones.firstWhere((z) => z.zone.id == 'zone_kitchen').isHazard, isTrue);
    expect(layout.routePassesHazard, isFalse);
  });

  test('hazard on route marks both adjacent segments', () {
    final layout = buildFloorPlanLayout(zones, route, {'zone_hallway'});
    expect(layout.routePassesHazard, isTrue);
    expect(layout.waypoints.first.isHazard, isTrue);
    expect(layout.hazardousSegments, contains(0));
  });

  test('segment crossing a hazard tile is marked even without a hazard stop', () {
    const lineZones = [
      ZoneInfo(id: 'left', floorId: 'floor', unitId: null, label: 'Left', kind: 'room', x: 0, y: 0),
      ZoneInfo(id: 'hazard', floorId: 'floor', unitId: null, label: 'Hazard', kind: 'room', x: 5, y: 0),
      ZoneInfo(id: 'right', floorId: 'floor', unitId: null, label: 'Right', kind: 'room', x: 10, y: 0),
    ];
    const crossing = [
      Waypoint(id: 'left', label: 'Left'),
      Waypoint(id: 'right', label: 'Right'),
    ];
    final layout = buildFloorPlanLayout(lineZones, crossing, {'hazard'});
    expect(layout.routePassesHazard, isTrue);
    expect(layout.hazardousSegments, contains(0));
  });

  test('empty route and empty zones are finite', () {
    final empty = buildFloorPlanLayout([], [], {});
    expect(empty.zones, isEmpty);
    expect(empty.waypoints, isEmpty);
    final zoneOnly = buildFloorPlanLayout(zones, [], {});
    expect(zoneOnly.zones.length, zones.length);
    expect(zoneOnly.waypoints, isEmpty);
    final routeOnly = buildFloorPlanLayout([], route, {});
    expect(routeOnly.waypoints.length, route.length);
    expect(routeOnly.waypoints.map((w) => w.position.x), everyElement(.5));
    expect(routeOnly.waypoints.map((w) => w.position.y).toSet().length, route.length);
  });

  test('one-zone and collinear coordinates avoid division by zero', () {
    final one = buildFloorPlanLayout([zones[2]], route, {});
    expect(one.zones.single.position.x.isFinite, isTrue);
    expect(one.zones.single.position.y.isFinite, isTrue);
    final line = buildFloorPlanLayout([
      zones[2],
      const ZoneInfo(id: 'line2', floorId: 'flr_03', unitId: null, label: 'Line 2', kind: 'room', x: 5, y: 8),
    ], route, {});
    expect(line.zones.every((z) => z.position.x == line.zones.first.position.x), isTrue);
    expect(line.zones.every((z) => z.position.y.isFinite), isTrue);
  });

  test('bad coordinate values become zero', () {
    final zone = ZoneInfo.fromJson({
      'id': 'bad', 'floor_id': 'flr_03', 'unit_id': null,
      'label': 'Bad', 'kind': 'room', 'pos_x': 'n/a', 'pos_y': double.nan,
    });
    expect(zone.x, 0);
    expect(zone.y, 0);
  });
}
