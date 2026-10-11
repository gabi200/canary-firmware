// The alarm screen's floor plan: which blocks and rooms are drawn, which are
// red, where the exit goes and the way out. Floor 3 of bld_007 as the hub
// sends it.
import 'package:canary_resident/src/logic/escape_plan.dart';
import 'package:canary_resident/src/logic/relative_location.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/models/zone_info.dart';
import 'package:flutter_test/flutter_test.dart';

ZoneInfo _z(String id, String label, String unit, String kind, double x, double y, {String floor = 'flr_03'}) =>
    ZoneInfo.fromJson({
      'id': id, 'label': label, 'unit_id': unit, 'kind': kind, 'pos_x': x, 'pos_y': y,
      'floor_id': floor, 'floor_label': floor == 'flr_03' ? 'Etaj 3' : 'Etaj 5',
      'unit_label': switch (unit) {
        'common' => 'Spații comune',
        'unit_0312' => 'Ap. 12',
        'unit_0313' => 'Ap. 13',
        'unit_0314' => 'Ap. 14',
        _ => 'Ap. 52',
      },
      if (unit == 'common') 'unit_kind': 'common',
    });

final _zones = [
  _z('zone_kitchen', 'Bucătărie', 'unit_0312', 'kitchen', 2, 2),
  _z('zone_bedroom', 'Dormitor', 'unit_0312', 'bedroom', 8, 2),
  _z('zone_hallway', 'Hol scară', 'common', 'hallway', 5, 5),
  _z('zone_boiler', 'Centrală termică', 'common', 'boiler', 2, 8),
  _z('bath_12', 'Baie', 'unit_0312', 'bathroom', 5, 1),
  _z('living_12', 'Living', 'unit_0312', 'living_room', 5, 3),
  _z('kitchen_13', 'Bucătărie', 'unit_0313', 'kitchen', 12, 2),
  _z('bath_13', 'Baie', 'unit_0313', 'bathroom', 15, 1),
  _z('living_13', 'Living', 'unit_0313', 'living_room', 15, 3),
  _z('bedroom_13', 'Dormitor', 'unit_0313', 'bedroom', 18, 2),
  _z('kitchen_14', 'Bucătărie', 'unit_0314', 'kitchen', 12, 8),
  _z('bath_14', 'Baie', 'unit_0314', 'bathroom', 15, 7),
  _z('living_14', 'Living', 'unit_0314', 'living_room', 15, 9),
  _z('bedroom_14', 'Dormitor', 'unit_0314', 'bedroom', 18, 8),
  _z('kitchen_52', 'Bucătărie', 'unit_0552', 'kitchen', 2, 2, floor: 'flr_05'),
];

const _route = EvacuationRoute(
  id: 'er_flr03', label: '', toAssemblyPointId: 'ap_main', fromZoneId: 'zone_hallway',
  path: ['zone_hallway', 'stairwell_main', 'exit_front', 'ap_main'],
  waypoints: [
    Waypoint(id: 'zone_hallway', label: 'Hol scară', kind: 'hallway'),
    Waypoint(id: 'stairwell_main', label: 'Scara principală', kind: 'stairwell'),
    Waypoint(id: 'exit_front', label: 'Ieșirea din față', kind: 'exit'),
    Waypoint(id: 'ap_main', label: 'Punct adunare', kind: 'assembly_point'),
  ],
);

ResidentHome _home(String unit) => residentHome([(id: unit, label: null, floorLabel: null)], _zones);

Incident _gas(String zone) => Incident(
    id: 'inc', buildingId: 'bld_007', hazardType: 'combustible_gas', severity: 'critical', state: 'evacuation',
    primaryZoneId: zone);

EscapePlan _plan(String zone, String unit, {EvacuationRoute? route = _route}) =>
    escapePlan(incident: _gas(zone), zones: _zones, home: _home(unit), route: route);

/// "id: kind, red, rooms(red ones marked *)" per block, for compact checks.
List<String> _summary(EscapePlan p) => [
      for (final b in p.blocks)
        '${b.id}: ${b.kind.name}${b.danger ? ' RED' : ''}'
            '${b.rooms.isEmpty ? '' : ' [${b.rooms.map((r) => '${r.label}${r.danger ? '*' : ''}').join(', ')}]'}',
    ];

void main() {
  test('danger in your own kitchen: your rooms drawn, the kitchen red, others one block each', () {
    final p = _plan('zone_kitchen', 'unit_0312');
    expect(_summary(p), [
      'unit_0312: home RED [Bucătărie*, Dormitor, Baie, Living]',
      'unit_0313: apartment',
      'unit_0314: apartment',
      'zone_hallway: common',
      'exit: exit',
    ]);
    expect(p.block('zone_hallway')!.onRoute, isTrue);
    expect(p.block('zone_boiler'), isNull, reason: 'not on the way out, no danger');
    expect(p.path, ['unit_0312', 'zone_hallway', 'exit']);
    expect(p.floorLabel, 'Etaj 3');
  });

  test('danger next door: that apartment is one red block with only the problem room inside', () {
    final p = _plan('zone_kitchen', 'unit_0313');
    expect(_summary(p), [
      'unit_0312: apartment RED [Bucătărie*]',
      'unit_0313: home [Bucătărie, Baie, Living, Dormitor]',
      'unit_0314: apartment',
      'zone_hallway: common',
      'exit: exit',
    ]);
    expect(p.path, ['unit_0313', 'zone_hallway', 'exit']);
    expect(p.block('unit_0312')!.label, 'Ap. 12');
  });

  test('only the danger is red', () {
    final p = _plan('zone_kitchen', 'unit_0314');
    final red = [for (final b in p.blocks) if (b.danger) b.id];
    final redRooms = [for (final b in p.blocks) for (final r in b.rooms) if (r.danger) r.zoneId];
    expect(red, ['unit_0312']);
    expect(redRooms, ['zone_kitchen']);
  });

  test('blocks cover their rooms: apartments side by side, the hallway under Ap. 12, the exit under it', () {
    final p = _plan('zone_kitchen', 'unit_0312');
    expect(p.block('unit_0312')!.area, (col: 0, row: 0, cols: 3, rows: 2));
    expect(p.block('unit_0313')!.area, (col: 3, row: 0, cols: 3, rows: 2));
    expect(p.block('zone_hallway')!.area, (col: 1, row: 2, cols: 1, rows: 1));
    expect(p.block('exit')!.area, (col: 1, row: 3, cols: 1, rows: 1));
    expect(p.block('exit')!.label, 'Ieșirea din față');
    expect((p.cols, p.rows), (6, 5));
    // Rooms keep their own cells inside the home block.
    final rooms = {for (final r in p.block('unit_0312')!.rooms) r.label: r.cell};
    expect(rooms['Bucătărie'], (col: 0, row: 0));
    expect(rooms['Living'], (col: 1, row: 1));
  });

  test('danger in a common area: the area itself is red; the boiler room shows only then', () {
    expect(_summary(_plan('zone_hallway', 'unit_0312')), contains('zone_hallway: common RED'));
    final boiler = _plan('zone_boiler', 'unit_0312');
    expect(_summary(boiler), contains('zone_boiler: common RED'));
    expect(boiler.block('unit_0312')!.danger, isFalse);
  });

  test('danger on another floor: your floor, nothing red', () {
    final p = _plan('kitchen_52', 'unit_0312');
    expect(p.blocks.where((b) => b.danger), isEmpty);
    expect(p.block('unit_0312')!.kind, PlanBlockKind.home);
    expect(p.floorLabel, 'Etaj 3');
  });

  test('no route: no exit and no way out; home unknown: the danger floor, no home', () {
    final noRoute = _plan('zone_kitchen', 'unit_0312', route: null);
    expect(noRoute.block('exit'), isNull);
    expect(noRoute.path, ['unit_0312']);

    final nobody = escapePlan(incident: _gas('kitchen_13'), zones: _zones, home: ResidentHome.none, route: _route);
    expect(nobody.blocks.where((b) => b.kind == PlanBlockKind.home), isEmpty);
    expect(nobody.block('unit_0313')!.danger, isTrue);
    expect(nobody.path, ['zone_hallway', 'exit']);
  });

  test('unknown zones: an empty plan', () {
    expect(_plan('zone_nowhere', 'unit_9999').isEmpty, isTrue);
  });
}
