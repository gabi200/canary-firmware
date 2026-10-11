// Test buttons in Romanian at 360 dp with 1.3x text: the sensor sheet's
// "Testează senzorul" section (own sensors only), the live result row, the
// "Ultimul test" line, "Testează-mi senzorii" with "Testează toate alarmele",
// and the manager's list under the apartment picker.
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/ui/sensor_test_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

Map<String, Object?> _node(String id, String kind, String name, {bool online = true, Object? last}) => {
      'node_id': id, 'kind': kind, 'name': name, 'online': online, 'stale': false,
      'last_seen_ts': _ago(Duration.zero), 'status': 'ok', 'headline': 'Totul e în regulă',
      'indicators': kind == 'air'
          ? [{'key': 'air_quality', 'level': 'ok', 'value': 'Bună'}]
          : [
              {'key': 'leak', 'level': 'ok', 'value': 'Nicio scurgere'},
              {'key': 'valve', 'level': 'ok', 'value': 'Deschis'},
            ],
      'last_command': last,
    };

Map<String, Object?> _summary() => {
      'building_id': 'bld', 'status': 'ok', 'headline': 'Totul e în regulă', 'nodes_total': 5, 'nodes_online': 4,
      'zones': [
        {'zone_id': 'zone_kitchen', 'zone_label': 'Bucătărie', 'status': 'ok', 'nodes': [
          _node('air-kitchen', 'air', 'Aer bucătărie', last: {
            'command_id': 'old', 'command': 'TEST', 'status': 'accepted', 'detail': 'self_test',
            'requested_by_name': 'Ana Popescu', 'sent_ts': _ago(const Duration(seconds: 151)),
            'result_ts': _ago(const Duration(seconds: 150)),
          }),
          _node('water-kitchen', 'water', 'Apă bucătărie'),
        ]},
        {'zone_id': 'zone_bedroom', 'zone_label': 'Dormitor', 'status': 'ok', 'nodes': [
          _node('air-bedroom', 'air', 'Aer dormitor'),
          _node('air-closet', 'air', 'Aer debara', online: false),
        ]},
        {'zone_id': 'zone_boiler', 'zone_label': 'Centrala', 'status': 'ok', 'nodes': [
          _node('air-boiler', 'air', 'Aer centrală'),
        ]},
      ],
    };

final _zones = [
  {'id': 'zone_kitchen', 'label': 'Bucătărie', 'unit_id': 'unit_0312', 'unit_label': 'Ap. 12'},
  {'id': 'zone_bedroom', 'label': 'Dormitor', 'unit_id': 'unit_0312', 'unit_label': 'Ap. 12'},
  {'id': 'zone_boiler', 'label': 'Centrala', 'unit_id': 'common', 'unit_label': 'Comun Etaj 3'},
];

/// Commands are relayed (202 "sent"); the device's answer shows up in the
/// command list (the app's poll fallback: no WebSocket in tests).
FakeHub _hub({String role = 'resident'}) {
  final hub = FakeHub()
    ..on('GET /api/v1/buildings/bld/summary', (_) => (200, _summary()))
    ..reply('GET /api/v1/buildings/bld/zones', 200, _zones)
    ..reply('GET /api/v1/me', 200, {
      'user_id': 'usr_ana', 'username': 'ana', 'role': role,
      'units': role == 'resident'
          ? [{'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'building_id': 'bld', 'kind': 'residential'}]
          : [],
    })
    ..reply('GET /api/v1/me/care-profiles', 200, const []);
  var n = 0;
  for (final id in ['air-kitchen', 'water-kitchen', 'air-bedroom', 'air-closet', 'air-boiler']) {
    String? last;
    hub.on('POST /api/v1/nodes/$id/commands', (r) {
      last = 'cmd${n++}';
      return (202, {'command_id': last, 'node_id': id, 'command': (r.data as Map)['command'], 'status': 'sent'});
    });
    hub.on('GET /api/v1/nodes/$id/commands', (_) => (200, [
          if (last != null)
            {'command_id': last, 'command': 'TEST', 'status': 'accepted', 'detail': 'self_test', 'sent_ts': _ago(Duration.zero)},
        ]));
    hub.on('GET /api/v1/nodes/$id/history', (r) => (200, {'node_id': id, 'minutes': 15, 'points': const []}));
  }
  return hub;
}

Future<FakeHub> _pump(WidgetTester tester, {String role = 'resident'}) async {
  phoneView(tester);
  final storage = await signedInStorage(role: role);
  final hub = _hub(role: role);
  await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, hub), child: const CanaryApp()));
  await settle(tester);
  return hub;
}

Future<void> _reveal(WidgetTester tester, Finder f, {Finder? scrollable, double delta = 200}) async {
  await tester.scrollUntilVisible(f, delta, scrollable: scrollable ?? find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await settle(tester);
}

/// The sensor's sheet; from a resident's home through the [room]'s page.
Future<void> _openSheet(WidgetTester tester, String name, {String? room}) async {
  if (room != null) await openRoom(tester, room);
  await _reveal(tester, find.text(name));
  await tester.tap(find.text(name));
  await settle(tester);
}

Iterable<RequestOptions> _posts(FakeHub hub) => hub.requests.where((r) => r.method == 'POST');

/// The screens' vertical lists (the picker's chip rows scroll sideways).
Finder _vertical() => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);

void main() {
  test('checklist names: the room only when the name lacks it', () {
    expect(withRoom('Bucatarie', 'Bucătărie · aer'), 'Bucătărie · aer');
    expect(withRoom('Dormitor', 'Aer dormitor'), 'Aer dormitor');
    expect(withRoom('Hol', 'canary'), 'Hol · canary');
    expect(withRoom(null, 'canary'), 'canary');
  });

  testWidgets('own air sensor: test button, live result, "Ultimul test" on the room card', (tester) async {
    final hub = await _pump(tester);

    await openRoom(tester, 'Bucătărie');
    await _reveal(tester, find.text('Aer bucătărie'));
    expect(find.text('Ultimul test: reușit · acum 2 min'), findsOneWidget);
    expect(find.text('Netestat'), findsWidgets);

    await _reveal(tester, find.text('Aer bucătărie'));
    await tester.tap(find.text('Aer bucătărie'));
    await settle(tester);
    expect(find.text('Testează senzorul'), findsOneWidget);
    expect(find.text('Senzorul va suna și va clipi 4 secunde.'), findsOneWidget);
    expect(find.text('Ultimul test: reușit · acum 2 min'), findsNWidgets(2)); // card + sheet
    final test = find.widgetWithText(FilledButton, 'Testează alarma (4 s)');
    expect(tester.getSize(test).height, greaterThanOrEqualTo(48));
    expect(find.widgetWithText(OutlinedButton, 'Oprește alarma'), findsOneWidget);

    await tester.tap(test);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trimis…'), findsOneWidget);
    expect(_posts(hub).single.data, {'command': 'TEST'});
    expect(tester.widget<FilledButton>(test).onPressed, isNull); // one at a time

    await tester.pump(const Duration(seconds: 3)); // poll fallback finds the answer
    await settle(tester);
    expect(find.text('Reușit'), findsOneWidget);
    expect(find.text('Test alarmă · autotest pornit'), findsOneWidget);
    expect(tester.getSemantics(find.text('Reușit')), isNotNull);
    expect(tester.widget<FilledButton>(test).onPressed, isNotNull);
  });

  testWidgets('sketch: each room shows its last test', (tester) async {
    await _pump(tester);
    await openAllSensors(tester);
    await _reveal(tester, find.text('Schiță'));
    await tester.tap(find.text('Schiță'));
    await settle(tester);
    await _reveal(tester, find.text('Test: reușit · acum 2 min'));
    expect(find.text('Netestat'), findsNWidgets(2)); // bedroom + boiler
    expect(find.bySemanticsLabel(RegExp(r'^Bucătărie, .*Ultimul test: reușit · acum 2 min, 2 senzori$')), findsOneWidget);
  });

  testWidgets('common area: no test buttons, just the note', (tester) async {
    final hub = await _pump(tester);
    await _openSheet(tester, 'Aer centrală', room: 'Centrala');
    expect(find.text('Testează senzorul'), findsOneWidget);
    expect(find.text('Doar administratorul poate testa senzorii din spațiile comune.'), findsOneWidget);
    expect(find.text('Testează alarma (4 s)'), findsNothing);
    expect(find.text('Oprește alarma'), findsNothing);
    expect(_posts(hub), isEmpty);
  });

  testWidgets('water: closing the valve asks first', (tester) async {
    final hub = await _pump(tester);
    await _openSheet(tester, 'Apă bucătărie', room: 'Bucătărie');
    // Valve open: only "close" is offered (plus silence).
    final close = find.widgetWithText(FilledButton, 'Închide robinetul');
    expect(close, findsOneWidget);
    expect(find.text('Deschide robinetul'), findsNothing);

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('Robinetul va opri apa în apartament până îl redeschizi.'), findsOneWidget);
    await tester.tap(find.text('Anulează'));
    await tester.pumpAndSettle();
    expect(_posts(hub), isEmpty);

    await tester.tap(close);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Închide robinetul')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_posts(hub).single.data, {'command': 'CLOSE'});
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.text('Reușit'), findsOneWidget);
  });

  testWidgets('"Testează-mi senzorii": own sensors, test-all checklist, never a valve command', (tester) async {
    final hub = await _pump(tester);
    await tester.tap(find.byTooltip('Setări'));
    await settle(tester);
    await _reveal(tester, find.text('Testează-mi senzorii'));
    await tester.tap(find.text('Testează-mi senzorii'));
    await settle(tester);

    expect(find.widgetWithText(AppBar, 'Testează-mi senzorii'), findsOneWidget);
    expect(find.text('Aer centrală'), findsNothing); // common area
    final list = find.byType(Scrollable).last;
    await _reveal(tester, find.text('Doar administratorul poate testa senzorii din spațiile comune.'), scrollable: list);
    await _reveal(tester, find.text('Testează toate alarmele'), scrollable: list, delta: -200);

    await tester.tap(find.text('Testează toate alarmele'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Se testează 1 din 2…'), findsOneWidget);
    expect(find.text('Deconectat, sărit'), findsOneWidget); // the offline closet sensor
    expect(find.text('În așteptare'), findsOneWidget);
    expect(_posts(hub).map((r) => r.path), ['/api/v1/nodes/air-kitchen/commands']);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
    expect(find.text('Gata: 2 din 2 reușite'), findsOneWidget);
    expect(_posts(hub).map((r) => r.path), ['/api/v1/nodes/air-kitchen/commands', '/api/v1/nodes/air-bedroom/commands']);
    expect(_posts(hub).map((r) => (r.data as Map)['command']).toSet(), {'TEST'});
  });

  testWidgets('manager: first apartment by default, unit names across flats, who tested', (tester) async {
    final hub = await _pump(tester, role: 'hoa_manager');
    await _reveal(tester, find.text('Testează senzorii'));
    await tester.tap(find.text('Testează senzorii'));
    await settle(tester);

    // Picker on top; Ap. 12 picked: plain room names, its own test-all.
    final chip = find.ancestor(of: find.text('Ap. 12'), matching: find.byType(ChoiceChip));
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(find.text('Bucătărie'), findsNWidgets(2)); // room chip + heading
    expect(find.text('Bucătărie · Ap. 12'), findsNothing);
    expect(find.text('Aer centrală'), findsNothing);
    expect(find.text('Testează toate alarmele · Ap. 12'), findsOneWidget);
    expect(find.text('Ultimul test: reușit · acum 2 min · Ana Popescu'), findsOneWidget);
    expect(find.text('CONECTAT'), findsWidgets);
    final list = _vertical().last;
    await _reveal(tester, find.text('DECONECTAT'), scrollable: list);
    expect(find.text('Senzorul e deconectat. Îl poți testa când revine.'), findsOneWidget);

    // Whole building: every room with its unit, and no building-wide test-all.
    await tester.ensureVisible(find.text('Toată clădirea'));
    await settle(tester);
    await tester.tap(find.text('Toată clădirea'));
    await settle(tester);
    await _reveal(tester, find.text('Bucătărie · Ap. 12'), scrollable: list, delta: -200);
    expect(find.textContaining('Testează toate alarmele'), findsNothing);
    await _reveal(tester, find.text('Alege un apartament de sus ca să-i testezi toate alarmele deodată.'),
        scrollable: list, delta: -200);
    await _reveal(tester, find.text('Centrala · Comun Etaj 3'), scrollable: list);
    await _reveal(tester, find.text('Aer centrală'), scrollable: list);
    expect(find.text('Doar administratorul poate testa senzorii din spațiile comune.'), findsNothing);
    expect(_posts(hub), isEmpty);
  });

  testWidgets('dispatcher: no test section', (tester) async {
    await _pump(tester, role: 'dispatcher_external');
    await _openSheet(tester, 'Aer bucătărie');
    expect(find.text('Testează senzorul'), findsNothing);
    expect(find.text('Testează senzorii'), findsNothing);
  });
}
