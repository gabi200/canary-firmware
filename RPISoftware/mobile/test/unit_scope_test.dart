// The apartment picker over the sensor lists (Romanian, 360 dp, 1.3x text):
// staff get it pinned on top of the dashboard and "Testează senzorii", the
// first apartment picked by default, a rooms row, unit names across flats and
// a test-all narrowed to the pick; residents with one apartment never see it.
import 'dart:convert';

import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/logic/unit_scope.dart';
import 'package:canary_resident/src/models/summary.dart';
import 'package:canary_resident/src/models/zone_info.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/theme.dart';
import 'package:canary_resident/src/ui/widgets/room_tiles.dart';
import 'package:canary_resident/src/ui/widgets/unit_scope_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

Map<String, Object?> _node(String id, String kind, String name, {String status = 'ok'}) => {
      'node_id': id, 'kind': kind, 'name': name, 'online': true, 'stale': false,
      'last_seen_ts': DateTime.now().toUtc().toIso8601String(), 'status': status, 'headline': 'Totul e în regulă',
      'indicators': const [],
    };

Map<String, Object?> _zone(String id, String label, String unit, String unitLabel, List<Object?> nodes,
        {bool withUnit = true}) =>
    {
      'zone_id': id, 'zone_label': label, 'status': 'ok', 'nodes': nodes,
      if (withUnit) 'unit_id': unit,
      if (withUnit) 'unit_label': unitLabel,
    };

/// Three flats with the same room names, plus the common areas; listed out of
/// order, as a hub may.
final _zones = [
  _zone('z14_bed', 'Dormitor', 'unit_14', 'Ap. 14', [_node('a14b', 'air', 'Dormitor · aer', status: 'danger')]),
  _zone('z_hall', 'Hol scară', 'common', 'Spații comune', [_node('ahall', 'air', 'Hol scară · aer')]),
  _zone('z12_kit', 'Bucătărie', 'unit_12', 'Ap. 12', [_node('a12k', 'air', 'Ap12 bucătărie · aer')]),
  _zone('z12_liv', 'Living', 'unit_12', 'Ap. 12', [_node('a12l', 'air', 'Living · aer')]),
  _zone('z13_kit', 'Bucătărie', 'unit_13', 'Ap. 13', [_node('w13k', 'water', 'Ap13 bucătărie · apă')]),
  _zone('z13_bath', 'Baie', 'unit_13', 'Ap. 13', [_node('a13b', 'air', 'Baie · aer', status: 'attention')]),
];

/// `GET /zones` as the hub sends it (residents' test buttons need the units).
List<Map<String, Object?>> _zoneList(Iterable<Map<String, Object?>> zones) => [
      for (final z in zones) {'id': z['zone_id'], 'label': z['zone_label'], 'unit_id': z['unit_id'], 'unit_label': z['unit_label']},
    ];

FakeHub _hub({required String role, List<Map<String, Object?>>? zones, List<String> homes = const []}) {
  final shown = zones ?? _zones;
  final hub = FakeHub()
    ..on('GET /api/v1/buildings/bld/summary', (_) => (200, {
          'building_id': 'bld', 'status': 'ok', 'headline': 'Totul e în regulă', 'zones': shown,
        }))
    ..reply('GET /api/v1/buildings/bld/zones', 200, _zoneList(shown))
    ..reply('GET /api/v1/me', 200, {
      'user_id': 'usr_ana', 'username': 'ana', 'role': role,
      'units': [for (final u in homes) {'unit_id': u, 'building_id': 'bld', 'kind': 'residential'}],
    })
    ..reply('GET /api/v1/me/care-profiles', 200, const []);
  for (final id in ['a14b', 'ahall', 'a12k', 'a12l', 'w13k', 'a13b']) {
    hub.on('POST /api/v1/nodes/$id/commands', (r) => (202, {'command_id': 'c$id', 'node_id': id, 'command': 'TEST', 'status': 'sent'}));
    hub.reply('GET /api/v1/nodes/$id/commands', 200, const []);
  }
  return hub;
}

Future<Storage> _pump(WidgetTester tester, FakeHub hub, {required String role}) async {
  phoneView(tester);
  final storage = await signedInStorage(role: role);
  await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, hub), child: const CanaryApp()));
  await settle(tester);
  return storage;
}

Finder _chip(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip)).first;

bool _selected(WidgetTester tester, String label) => tester.widget<ChoiceChip>(_chip(label)).selected;

Future<void> _tapChip(WidgetTester tester, String label) async {
  await tester.ensureVisible(_chip(label));
  await settle(tester, 3);
  await tester.tap(_chip(label));
  await settle(tester);
}

Finder _vertical() => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

/// From the top of the screen's list down to [f].
Future<void> _reveal(WidgetTester tester, Finder f) async {
  final list = _vertical().last;
  tester.state<ScrollableState>(list).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(f, 200, scrollable: list);
  await settle(tester, 3);
}

(ZoneSummary, List<NodeAnalysis>) _room(Map<String, Object?> json) {
  final z = ZoneSummary.fromJson(json);
  return (z, z.nodes);
}

void main() {
  group('scope logic', () {
    final rooms = [for (final z in _zones) _room(z)];

    test('summary zones carry their unit; older hubs: null', () {
      final z = ZoneSummary.fromJson(_zones[2]);
      expect((z.unitId, z.unitLabel), ('unit_12', 'Ap. 12'));
      final old = ZoneSummary.fromJson(_zone('z', 'Hol', 'u', 'U', const [], withUnit: false));
      expect((old.unitId, old.unitLabel), (null, null));
    });

    test('apartments in natural order, then common areas; first apartment by default', () {
      final scope = resolveScope(rooms, const {}, ScopeChoice.none, staff: true);
      expect(scope.units.map((u) => u.label), ['Ap. 12', 'Ap. 13', 'Ap. 14', 'Spații comune']);
      expect(scope.unit?.label, 'Ap. 12');
      expect(scope.shown.map((r) => r.label), ['Bucătărie', 'Living']);
      expect(scope.showsRooms, isTrue);
      expect(scope.label, 'Ap. 12');
      // Inside the flat: plain names; the sheet still says which flat.
      expect(scope.labelOf(scope.shown.first), 'Bucătărie');
      expect(scope.sheetLabelOf(scope.shown.first), 'Bucătărie · Ap. 12');
      expect(compareNatural('Ap. 9', 'Ap. 12'), lessThan(0));
      expect(compareNatural('Ap. 12', 'Ap. 13'), lessThan(0));
    });

    test('counts and the worst sensor status per unit', () {
      final scope = resolveScope(rooms, const {}, ScopeChoice.none, staff: true);
      final byLabel = {for (final u in scope.units) u.label: u};
      expect(byLabel['Ap. 12']!.sensorCount, 2);
      expect(byLabel['Ap. 12']!.status, 'ok');
      expect(byLabel['Ap. 13']!.status, 'attention');
      expect(byLabel['Ap. 14']!.status, 'danger');
      expect(scope.sensorCount, 6);
      expect(scope.status, 'danger');
      expect(worstStatus(['unknown', 'ok']), 'ok');
      expect(worstStatus(const []), 'unknown');
    });

    test('a picked room, the whole building, a stale pick', () {
      final room = resolveScope(rooms, const {}, const ScopeChoice(unitId: 'unit_13', zoneId: 'z13_bath'), staff: true);
      expect(room.shown.map((r) => r.zoneId), ['z13_bath']);
      expect(room.label, 'Baie · Ap. 13');

      final all = resolveScope(rooms, const {}, const ScopeChoice.wholeBuilding(), staff: true);
      expect(all.unit, isNull);
      expect(all.shown.length, 6);
      expect(all.showsRooms, isFalse);
      expect([for (final r in all.shown) all.labelOf(r)],
          ['Dormitor · Ap. 14', 'Hol scară · Spații comune', 'Bucătărie · Ap. 12', 'Living · Ap. 12', 'Bucătărie · Ap. 13', 'Baie · Ap. 13']);

      final gone = resolveScope(rooms, const {}, const ScopeChoice(unitId: 'unit_99'), staff: true);
      expect(gone.unit?.label, 'Ap. 12');
    });

    test('units from the zone list when the summary has none; neither: no picker', () {
      final bare = [for (final z in _zones) _room({...z}..remove('unit_id')..remove('unit_label'))];
      final infos = {
        for (final z in _zones)
          z['zone_id'] as String: ZoneInfo.fromJson(
              {'id': z['zone_id'], 'label': z['zone_label'], 'unit_id': z['unit_id'], 'unit_label': z['unit_label']}),
      };
      final fromInfos = resolveScope(bare, infos, ScopeChoice.none, staff: true);
      expect(fromInfos.units.map((u) => u.label), ['Ap. 12', 'Ap. 13', 'Ap. 14', 'Spații comune']);
      expect(fromInfos.units.last.common, isTrue);

      final none = resolveScope(bare, const {}, ScopeChoice.none, staff: true);
      expect(none.hasPicker, isFalse);
      expect(none.shown.length, 6);
    });

    test('residents: one flat + common areas get no picker; two flats get one, without rooms', () {
      final one = [for (final z in _zones.where((z) => z['unit_id'] == 'unit_12' || z['unit_id'] == 'common')) _room(z)];
      final single = resolveScope(one, const {}, ScopeChoice.none, staff: false);
      expect(single.hasPicker, isFalse);
      expect(single.shown.length, 3);
      expect(single.labelOf(single.shown.first), 'Hol scară'); // plain, as before

      final two = [for (final z in _zones.where((z) => z['unit_id'] != 'unit_14')) _room(z)];
      final both = resolveScope(two, const {}, const ScopeChoice(unitId: 'unit_13', zoneId: 'z13_bath'), staff: false);
      expect(both.units.map((u) => u.label), ['Ap. 12', 'Ap. 13', 'Spații comune']);
      expect(both.unit?.label, 'Ap. 13');
      expect(both.room, isNull); // no rooms row for residents
      expect(both.showsRooms, isFalse);
    });

    test('the pick survives as JSON', () {
      for (final c in [const ScopeChoice(unitId: 'unit_12', zoneId: 'z12_kit'), const ScopeChoice.wholeBuilding()]) {
        expect(ScopeChoice.fromJson(jsonDecode(jsonEncode(c.toJson()))), c);
      }
      expect(ScopeChoice.fromJson('junk'), ScopeChoice.none);
    });
  });

  testWidgets('staff dashboard: picker on top, first apartment, rooms row, unit names across flats', (tester) async {
    await _pump(tester, _hub(role: 'hoa_manager'), role: 'hoa_manager');

    expect(find.byType(UnitScopeBar), findsOneWidget);
    final xs = [
      for (final l in ['Ap. 12', 'Ap. 13', 'Ap. 14', 'Spații comune', 'Toată clădirea']) tester.getTopLeft(find.text(l)).dx,
    ];
    expect([...xs]..sort(), xs, reason: 'natural order, common areas, then the whole building');
    expect(_selected(tester, 'Ap. 12'), isTrue);
    expect(_selected(tester, 'Toate camerele'), isTrue);
    expect(find.bySemanticsLabel(RegExp(r'^Ap\. 12, 2 senzori, ok')), findsOneWidget);
    final danger = tester.widget<Icon>(find.descendant(of: _chip('Ap. 14'), matching: find.byIcon(Icons.error)));
    // The alarm red, as the active theme draws status colours on its surface.
    expect(danger.color, tester.element(_chip('Ap. 14')).palette.ink(HazardColors.alarm));

    await _reveal(tester, find.text('Living · aer'));
    expect(find.text('Ap12 bucătărie · aer'), findsOneWidget);
    expect(find.text('Baie · aer'), findsNothing);
    expect(find.text('Hol scară · aer'), findsNothing);
    // The picker stays pinned while the list scrolls.
    expect(find.text('Ap. 12').hitTestable(), findsOneWidget);

    await _tapChip(tester, 'Ap. 13');
    expect(_selected(tester, 'Ap. 13'), isTrue);
    await _reveal(tester, find.text('Baie · aer'));
    expect(find.text('Living · aer'), findsNothing);

    await _tapChip(tester, 'Baie');
    expect(find.text('Ap13 bucătărie · apă'), findsNothing);
    expect(find.text('Baie · aer'), findsOneWidget);

    await _tapChip(tester, 'Toată clădirea');
    expect(find.text('Toate camerele'), findsNothing);
    await _reveal(tester, find.text('Bucătărie · Ap. 12'));
    await _reveal(tester, find.text('Bucătărie · Ap. 13'));
  });

  testWidgets('"Testează senzorii": same pick as the dashboard, remembered, test-all only there', (tester) async {
    final hub = _hub(role: 'system_admin');
    final storage = await _pump(tester, hub, role: 'system_admin');
    await _tapChip(tester, 'Ap. 13');
    await _tapChip(tester, 'Baie');

    await _reveal(tester, find.text('Testează senzorii'));
    await tester.tap(find.text('Testează senzorii'));
    await settle(tester);
    expect(_selected(tester, 'Ap. 13'), isTrue);
    expect(_selected(tester, 'Baie'), isTrue);
    expect(find.text('Living · aer'), findsNothing);

    await tester.tap(find.text('Testează toate alarmele · Baie · Ap. 13'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(hub.requests.where((r) => r.method == 'POST').map((r) => r.path), ['/api/v1/nodes/a13b/commands']);

    // Remembered on the device for this building (ids only).
    expect(jsonDecode(storage.sensorScope!), {'building': 'bld', 'unit': 'unit_13', 'zone': 'z13_bath'});
  });

  testWidgets('resident with one apartment: no picker on home or "Testează-mi senzorii"', (tester) async {
    final mine = _zones.where((z) => z['unit_id'] == 'unit_12' || z['unit_id'] == 'common').toList();
    await _pump(tester, _hub(role: 'resident', zones: mine, homes: ['unit_12']), role: 'resident');
    expect(find.byType(UnitScopeBar), findsNothing);
    // A tile per room: the flat's, then the common areas it can see.
    final tiles = find.byType(RoomTileGrid);
    await _reveal(tester, tiles);
    expect(find.descendant(of: tiles, matching: find.text('Living')), findsOneWidget);
    expect(find.descendant(of: tiles, matching: find.text('Hol scară')), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Ap. 12'), findsOneWidget);

    await tester.tap(find.byTooltip('Setări'));
    await settle(tester);
    await _reveal(tester, find.text('Testează-mi senzorii'));
    await tester.tap(find.text('Testează-mi senzorii'));
    await settle(tester);
    expect(find.byType(UnitScopeBar), findsNothing);
    expect(find.text('Testează toate alarmele'), findsOneWidget);
  });

  testWidgets('resident with two apartments: one row, "Toate" last, first apartment by default', (tester) async {
    final mine = _zones.where((z) => z['unit_id'] != 'unit_14').toList();
    await _pump(tester, _hub(role: 'resident', zones: mine, homes: ['unit_12', 'unit_13']), role: 'resident');
    expect(find.byType(UnitScopeBar), findsOneWidget);
    expect(_selected(tester, 'Ap. 12'), isTrue);
    expect(find.text('Toate'), findsOneWidget);
    expect(find.text('Toată clădirea'), findsNothing);
    expect(find.text('Toate camerele'), findsNothing);
    // The picked flat's rooms only, and its name on top.
    final tiles = find.byType(RoomTileGrid);
    await _reveal(tester, tiles);
    expect(find.descendant(of: tiles, matching: find.text('Living')), findsOneWidget);
    expect(find.descendant(of: tiles, matching: find.text('Baie')), findsNothing);
    expect(find.widgetWithText(AppBar, 'Ap. 12'), findsOneWidget);
  });
}
