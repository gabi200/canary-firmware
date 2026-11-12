// The resident home (status first, room tiles, building strip, folding), the
// alarm screen starting from the resident's own apartment ("Unde ești acum?"),
// and the Auto / Light / Dark setting. Romanian at 360 dp with 1.3x text.
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:canary_resident/src/ui/room_screen.dart';
import 'package:canary_resident/src/ui/widgets/floor_plan_sketch.dart';
import 'package:canary_resident/src/ui/widgets/home_banner.dart';
import 'package:canary_resident/src/ui/widgets/room_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

Map<String, Object?> _air(String id, String name) => {
      'node_id': id, 'kind': 'air', 'name': name, 'online': true, 'stale': false,
      'last_seen_ts': DateTime.now().toUtc().toIso8601String(), 'status': 'ok', 'headline': 'Aerul e bun',
      'indicators': [
        {'key': 'air_quality', 'level': 'ok', 'value': 'Bună'},
      ],
    };

Map<String, Object?> _room(String id, String label, String unit, List<Map<String, Object?>> nodes) => {
      'zone_id': id, 'zone_label': label, 'unit_id': unit,
      'unit_label': unit == 'common' ? 'Spații comune' : 'Ap. 12', 'status': 'ok', 'nodes': nodes,
    };

/// Ana's summary: her flat's rooms and the common hallway, in hub order.
final _summary = {
  'building_id': 'bld', 'status': 'ok', 'headline': 'Totul e în regulă', 'nodes_total': 5, 'nodes_online': 5,
  'zones': [
    _room('zone_bath', 'Baie', 'unit_0312', [_air('air-bath', 'Aer baie')]),
    _room('zone_hallway', 'Hol scară', 'common', [_air('air-hall', 'Aer hol')]),
    _room('zone_kitchen', 'Bucătărie', 'unit_0312', [_air('air-kitchen', 'Aer bucătărie')]),
    _room('zone_living', 'Living', 'unit_0312', [_air('air-living', 'Aer living')]),
    _room('zone_bedroom', 'Dormitor', 'unit_0312', [_air('air-bedroom', 'Aer dormitor')]),
  ],
};

Map<String, Object?> _zone(String id, String label, String unit, String kind, double x, double y) => {
      'id': id, 'label': label, 'unit_id': unit, 'kind': kind, 'floor_id': 'flr_03', 'floor_label': 'Etaj 3',
      'unit_label': switch (unit) { 'common' => 'Spații comune', 'unit_0313' => 'Ap. 13', _ => 'Ap. 12' },
      if (unit == 'common') 'unit_kind': 'common',
      'pos_x': x, 'pos_y': y,
    };

/// The whole floor (every resident may read the building's zones).
final _zones = [
  _zone('zone_kitchen', 'Bucătărie', 'unit_0312', 'kitchen', 2, 2),
  _zone('zone_bath', 'Baie', 'unit_0312', 'bathroom', 5, 1),
  _zone('zone_living', 'Living', 'unit_0312', 'living_room', 5, 3),
  _zone('zone_bedroom', 'Dormitor', 'unit_0312', 'bedroom', 8, 2),
  _zone('zone_hallway', 'Hol scară', 'common', 'hallway', 5, 5),
  _zone('zone_kitchen_13', 'Bucătărie', 'unit_0313', 'kitchen', 12, 2),
];

Map<String, Object?> _me(String unit, String label) => {
      'user_id': 'u', 'username': 'u', 'role': 'resident',
      'units': [
        {'unit_id': unit, 'unit_label': label, 'building_id': 'bld', 'floor_label': 'Etaj 3', 'kind': 'residential'},
      ],
    };

FakeHub _hub({String unit = 'unit_0312', String label = 'Ap. 12'}) {
  final hub = FakeHub()
    ..reply('GET /api/v1/buildings/bld/summary', 200, _summary)
    ..reply('GET /api/v1/buildings/bld/zones', 200, _zones)
    ..reply('GET /api/v1/me', 200, _me(unit, label))
    ..reply('GET /api/v1/me/care-profiles', 200, const [{'id': 'cp', 'display_name': 'Ana', 'is_self': true}])
    ..reply('GET /api/v1/buildings/bld/evacuation', 200, {
      'assembly_points': [
        {'id': 'ap_main', 'label': 'Parcare față'},
      ],
      'routes': [
        {
          'id': 'r', 'path': ['zone_hallway', 'stairs', 'ap_main'], 'from_zone_id': 'zone_hallway',
          'to_assembly_point_id': 'ap_main',
          'waypoints': [
            {'id': 'zone_hallway', 'label': 'Hol scară'},
            {'id': 'stairs', 'label': 'Scara principală'},
            {'id': 'ap_main', 'label': 'Parcare față', 'kind': 'assembly_point'},
          ],
        },
      ],
    })
    ..on('POST /api/v1/incidents/inc/location', (r) => (200, {'incident_id': 'inc', ...r.data as Map}))
    ..reply('POST /api/v1/incidents/inc/checkin', 200, {'ok': true});
  for (final id in ['air-bath', 'air-hall', 'air-kitchen', 'air-living', 'air-bedroom']) {
    hub.reply('GET /api/v1/nodes/$id/history', 200, {
      'node_id': id, 'minutes': 15,
      'points': [
        {'ts': DateTime.now().toUtc().toIso8601String(), 'values': {'climate.temperature_c': 22.4, 'climate.humidity_percent': 40}},
      ],
    });
  }
  return hub;
}

const _gas = Incident(
    id: 'inc', buildingId: 'bld', hazardType: 'combustible_gas', severity: 'critical', state: 'alarm',
    primaryZoneId: 'zone_kitchen');

Widget _alarmApp(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: Consumer(builder: (context, ref, _) => MaterialApp(
            locale: ref.watch(localeProvider),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: const AlarmScreen(incidentId: 'inc'),
          )),
    );

/// Scrolls [f] fully into view on the current screen's list, then taps it.
Future<void> _tapVisible(WidgetTester tester, Finder f, {double delta = 120}) async {
  await tester.scrollUntilVisible(f, delta, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await settle(tester, 3);
  await tester.tap(f);
  await settle(tester);
}

Finder _filled(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)).first;

Finder _tile(String label) => find.descendant(of: find.byType(RoomTileGrid), matching: find.text(label));

void main() {
  testWidgets('home: the apartment on top, all is well, room tiles in order, building strip', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);

    expect(find.widgetWithText(AppBar, 'Ap. 12 · Etaj 3'), findsOneWidget);
    expect(find.text('bld'), findsNothing);
    expect(find.text('Totul e în regulă'), findsOneWidget);
    expect(find.text('Locuința ta e monitorizată'), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(RoomTileGrid), 200, scrollable: find.byType(Scrollable).first);
    // Kitchen, bathroom, bedroom, living room, then the common hallway.
    final order = ['Bucătărie', 'Baie', 'Dormitor', 'Living', 'Hol scară'];
    final at = [for (final l in order) tester.getTopLeft(_tile(l))];
    for (var i = 1; i < at.length; i++) {
      expect(at[i].dy > at[i - 1].dy || (at[i].dy == at[i - 1].dy && at[i].dx > at[i - 1].dx), isTrue,
          reason: '${order[i]} after ${order[i - 1]}');
    }
    expect(find.text('spațiu comun'), findsOneWidget);
    expect(find.textContaining('≈ 22 °C'), findsNWidgets(5)); // never broken inside
    expect(find.bySemanticsLabel(RegExp(r'^Bucătărie, Totul e în regulă, aproximativ 22 grade$')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Niciun incident activ'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Niciun incident activ'), findsOneWidget);
  });

  testWidgets('home: sections fold, a room opens inline or as a page, all remembered', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, hub), child: const CanaryApp()));
    await settle(tester);

    // The chevron shows the room's sensors in place, and hides them again.
    await tester.scrollUntilVisible(find.byType(RoomTileGrid), 200, scrollable: find.byType(Scrollable).first);
    final show = find.byTooltip('Arată senzorii').first;
    expect(tester.getSize(show).height, greaterThanOrEqualTo(48));
    await tester.tap(show);
    await settle(tester);
    expect(find.text('Aer bucătărie'), findsOneWidget);
    expect(find.byType(RoomScreen), findsNothing);
    expect(storage.roomsExpanded, ['zone_kitchen']);

    // "Camerele mele" folds away and stays folded after a restart.
    await _tapVisible(tester, find.text('Camerele mele'), delta: -120);
    expect(find.byType(RoomTileGrid), findsNothing);
    expect(storage.sectionsCollapsed, ['rooms']);
    expect(find.bySemanticsLabel('Camerele mele'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, hub), child: const CanaryApp()));
    await settle(tester);
    expect(find.byType(RoomTileGrid), findsNothing);
    await tester.tap(find.text('Camerele mele'));
    await settle(tester);
    expect(find.text('Aer bucătărie'), findsOneWidget, reason: 'the kitchen is still open inline');
    await tester.tap(find.byTooltip('Ascunde senzorii'));
    await settle(tester);
    expect(find.text('Aer bucătărie'), findsNothing);
    expect(storage.roomsExpanded, isEmpty);

    // Tapping the tile itself opens the room's page.
    await openRoom(tester, 'Dormitor');
    expect(find.byType(RoomScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Dormitor'), findsOneWidget);
    expect(find.text('Aer dormitor'), findsOneWidget);
  });

  testWidgets('home during an alarm in the flat: danger banner, the room and the strip say where', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(
      overrides: hubOverrides(storage, _hub(), incidents: const IncidentsState(incidents: [_gas], connected: true)),
      child: const CanaryApp(),
    ));
    await settle(tester);

    expect(find.descendant(of: find.byType(HomeStatusBanner), matching: find.text('Scurgere de gaz')),
        findsOneWidget);
    expect(find.text('În locuința ta: Bucătărie'), findsOneWidget);
    expect(find.text('Deschide instrucțiunile de evacuare'), findsOneWidget);
    await tester.scrollUntilVisible(find.byType(RoomTileGrid), 200, scrollable: find.byType(Scrollable).first);
    expect(_tile('Scurgere de gaz'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Clădirea: Scurgere de gaz'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('În locuința ta: Bucătărie'), findsWidgets); // the strip, under the banner's
  });

  testWidgets('alarm in your home: you, the plan, "Unde ești acum?" sent and remembered', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub();
    await tester.pumpWidget(_alarmApp(hubOverrides(storage, hub,
        incidents: const IncidentsState(incidents: [_gas], connected: true))));
    await settle(tester);

    expect(find.text('În locuința ta: Bucătărie'), findsOneWidget);
    expect(find.text('Tu: Ap. 12 · Etaj 3'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Acasă'), 120, scrollable: find.byType(Scrollable).first);
    expect(find.text('Unde ești acum?'), findsOneWidget);
    for (final answer in ['Acasă', 'În altă parte în clădire', 'Afară']) {
      expect(tester.getSize(_filled(answer)).height, greaterThanOrEqualTo(56));
    }

    await _tapVisible(tester, find.text('Acasă'));
    expect(hub.calls('POST', '/api/v1/incidents/inc/location').single.data, {'location': 'home'});
    expect(find.text('Trimis: Acasă'), findsOneWidget);
    expect(find.text('Ești: Acasă'), findsOneWidget);
    expect(find.textContaining('Pericolul e în locuința ta. Ieși acum'), findsOneWidget);
    expect(storage.incidentLocation('usr_ana/inc'), 'home');
    expect(storage.incidentLocation('usr_radu/inc'), isNull, reason: 'kept per account');
    expect(hub.calls('POST', '/api/v1/incidents/inc/checkin'), isEmpty);

    // The plan: affected rooms in words, the source marked as yours.
    final list = find.text('Bucătărie · Ap. 12 (sursa, locuința ta)');
    await tester.scrollUntilVisible(list, 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Etaj 3 · schiță, nu la scară'), findsOneWidget);
    // Her rooms are drawn, with "Tu"; the legend: Tu / Pericol / Ieșire.
    final plan = find.byType(IncidentPlan);
    for (final room in ['Bucătărie', 'Baie', 'Dormitor', 'Living']) {
      expect(find.descendant(of: plan, matching: find.text(room)), findsOneWidget, reason: room);
    }
    expect(find.descendant(of: plan, matching: find.text('Tu')), findsNWidgets(2)); // plan + legend
    expect(find.descendant(of: plan, matching: find.text('Pericol')), findsOneWidget);
    expect(find.descendant(of: plan, matching: find.text('Ieșire')), findsNWidgets(2)); // exit block + legend

    // Change the answer: outside also checks in as out and safe.
    await _tapVisible(tester, find.text('Schimbă'), delta: -120);
    await _tapVisible(tester, find.text('Afară'));
    expect(hub.calls('POST', '/api/v1/incidents/inc/location').last.data, {'location': 'outside'});
    expect(hub.calls('POST', '/api/v1/incidents/inc/checkin').single.data, {'status': 'safe_outside'});
    expect(find.textContaining('Rămâi afară și mergi la punctul de adunare: Parcare față.'), findsOneWidget);
    expect(find.text('Confirmat: Am ieșit, sunt în siguranță'), findsOneWidget);

    // Remembered for this incident.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_alarmApp(hubOverrides(storage, hub,
        incidents: const IncidentsState(incidents: [_gas], connected: true))));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('Ești: Afară'), 120, scrollable: find.byType(Scrollable).first);
    expect(find.text('Unde ești acum?'), findsNothing);
  });

  testWidgets('alarm next door: "Pe etajul tău", the neighbour\'s flat; no answer sent: kept on the phone',
      (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub(unit: 'unit_0313', label: 'Ap. 13')
      ..reply('POST /api/v1/incidents/inc/location', 503, {'detail': 'offline'});
    await tester.pumpWidget(_alarmApp(hubOverrides(storage, hub,
        incidents: const IncidentsState(incidents: [_gas], connected: true))));
    await settle(tester);

    expect(find.text('Pe etajul tău: Ap. 12'), findsOneWidget);
    expect(find.text('Tu: Ap. 13 · Etaj 3'), findsOneWidget);
    await _tapVisible(tester, find.text('În altă parte în clădire'));
    expect(find.text('Nu s-a trimis: fără conexiune. Răspunsul e salvat pe telefon; apasă din nou ca să-l trimiți.'),
        findsOneWidget);
    expect(find.textContaining('Ieși pe cea mai apropiată scară.'), findsOneWidget);
    expect(storage.incidentLocation('usr_ana/inc'), 'building');
    final list = find.text('Bucătărie · Ap. 12 (sursa)');
    await tester.scrollUntilVisible(list, 200, scrollable: find.byType(Scrollable).first);
    // The neighbour's flat is one block: its name and only the room in danger.
    final plan = find.byType(IncidentPlan);
    expect(find.descendant(of: plan, matching: find.text('Ap. 12')), findsOneWidget);
    expect(find.descendant(of: plan, matching: find.text('Bucătărie')), findsNWidgets(2)); // the red one + his
    expect(find.descendant(of: plan, matching: find.text('Baie')), findsNothing);
    expect(find.descendant(of: plan, matching: find.text('Tu')), findsWidgets);
  });

  testWidgets('appearance: follows the phone by default, Auto / Light / Dark saved on the device', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);
    // The test platform is light: the app follows it until the resident picks.
    expect(Theme.of(tester.element(find.byType(RoomTileGrid))).brightness, Brightness.light);

    await tester.tap(find.byTooltip('Setări'));
    await settle(tester);
    expect(find.text('Aspect'), findsOneWidget);
    await tester.tap(find.text('Întunecat'));
    await settle(tester);
    expect(storage.themeMode, 'dark');
    await tester.tap(find.text('Luminos'));
    await settle(tester);
    expect(storage.themeMode, 'light');
    expect(Theme.of(tester.element(find.text('Luminos'))).brightness, Brightness.light);
    await tester.tap(find.text('Automat'));
    await settle(tester);
    expect(storage.themeMode, 'system');
  });
}
