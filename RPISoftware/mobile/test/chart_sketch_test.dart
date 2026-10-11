// Full-screen chart (crosshair, gaps, stats, thresholds, swipe) and the home
// List / Sketch toggle, in Romanian at 360 dp with 1.3x text.
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/ui/sensor_chart_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

Map<String, Object?> _node(String id, String kind, String name, {String status = 'ok'}) => {
      'node_id': id, 'kind': kind, 'name': name, 'online': true, 'stale': false,
      'last_seen_ts': DateTime.now().toUtc().toIso8601String(), 'status': status, 'headline': 'Totul e în regulă',
      'indicators': kind == 'air'
          ? [
              {'key': 'air_quality', 'level': 'ok', 'value': 'Bună'},
              {'key': 'co', 'level': 'ok', 'value': 'Sigur'},
              {'key': 'gas', 'level': 'ok', 'value': 'Sigur'},
            ]
          : [
              {'key': 'leak', 'level': 'ok', 'value': 'Nicio scurgere'},
            ],
    };

final _summary = {
  'building_id': 'bld', 'status': 'ok', 'headline': 'Totul e în regulă', 'nodes_total': 4, 'nodes_online': 4,
  'zones': [
    {'zone_id': 'zone_kitchen', 'zone_label': 'Bucătărie', 'status': 'ok', 'nodes': [
      _node('air-kitchen', 'air', 'Aer bucătărie'), _node('water-kitchen', 'water', 'Apă bucătărie'),
    ]},
    {'zone_id': 'zone_bedroom', 'zone_label': 'Dormitor', 'status': 'ok', 'nodes': [_node('air-bedroom', 'air', 'Aer dormitor')]},
    {'zone_id': 'zone_boiler', 'zone_label': 'Centrala', 'status': 'ok', 'nodes': [_node('air-boiler', 'air', 'Aer centrală')]},
  ],
};

final _zones = [
  {'id': 'zone_kitchen', 'label': 'Bucătărie', 'unit_id': 'unit_0312', 'pos_x': 2, 'pos_y': 2},
  {'id': 'zone_bedroom', 'label': 'Dormitor', 'unit_id': 'unit_0312', 'pos_x': 8, 'pos_y': 2},
  {'id': 'zone_boiler', 'label': 'Centrala', 'unit_id': 'common', 'pos_x': 2, 'pos_y': 8},
];

/// One reading a minute for 40 min: CO spikes to 160 ppm at 25–29 min ago and
/// has a 6-minute gap (nulls) at 12–17 min ago.
Map<String, Object?> _history(RequestOptions r) {
  final now = DateTime.now().toUtc();
  const n = 40;
  return {
    'node_id': 'air-kitchen', 'minutes': int.parse('${r.queryParameters['minutes']}'),
    'points': [
      for (var i = 0; i < n; i++)
        () {
          final ago = n - 1 - i;
          final gap = ago >= 12 && ago <= 17;
          return {
            'ts': now.subtract(Duration(minutes: ago)).toIso8601String(),
            'values': {
              'climate.temperature_c': gap ? null : 22.0 + (i % 3) * 0.2,
              'climate.humidity_percent': 41.0,
              'particulate.pm2_5': 7, 'particulate.pm10': 9,
              'co.ppm': gap ? null : (ago >= 25 && ago <= 29 ? 160 : 4),
              'gas.adc': 600,
              'co.warn_ppm': 50, 'co.danger_ppm': 100, 'gas.warn_adc': 1500,
              'particulate.warn_pm2_5': 35, 'particulate.danger_pm2_5': 150,
              'particulate.warn_pm10': 100, 'particulate.danger_pm10': 250,
            },
          };
        }(),
    ],
  };
}

FakeHub _hub() => FakeHub()
  ..reply('GET /api/v1/buildings/bld/summary', 200, _summary)
  ..reply('GET /api/v1/buildings/bld/zones', 200, _zones)
  ..reply('GET /api/v1/me/care-profiles', 200, const [])
  ..on('GET /api/v1/nodes/air-kitchen/history', (r) => (200, _history(r)))
  ..on('GET /api/v1/nodes/air-bedroom/history', (r) => (200, _history(r)))
  ..on('GET /api/v1/nodes/air-boiler/history', (r) => (200, _history(r)));

Future<void> _scrollHome(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await settle(tester); // not pumpAndSettle: an incident room pulses forever
}

void main() {
  testWidgets('full-screen chart: stats, labelled thresholds, crosshair with gaps, swipe', (tester) async {
    phoneView(tester);
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);

    await openRoom(tester, 'Bucătărie');
    await _scrollHome(tester, find.text('Aer bucătărie'));
    await tester.tap(find.text('Aer bucătărie'));
    await settle(tester);
    final sheet = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('Monoxid de carbon').first, 150, scrollable: sheet);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Monoxid de carbon').first); // the tile, not the analysis row
    await settle(tester);

    expect(find.widgetWithText(AppBar, 'Monoxid de carbon'), findsOneWidget);
    expect(find.text('6h'), findsOneWidget);
    expect(find.text('Prag de alertă 50 ppm'), findsOneWidget);
    expect(find.text('Prag de pericol 100 ppm'), findsOneWidget);
    expect(find.text('fără date'), findsOneWidget);
    expect(find.text('Atinge și trage pe grafic ca să vezi valoarea exactă.'), findsOneWidget);

    // Stats ignore the gap: min 4, max 160.
    await tester.scrollUntilVisible(find.text('Medie'), 100, scrollable: find.byType(Scrollable).last);
    expect(find.text('Acum'), findsOneWidget);
    expect(find.text('4 ppm'), findsWidgets);
    expect(find.text('160 ppm'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Monoxidul de carbon e un gaz fără miros'), 100,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Monoxidul de carbon e un gaz fără miros'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Prag de alertă 50 ppm'), -100, scrollable: find.byType(Scrollable).last);

    // Crosshair: drag across the chart; the reading is a live region.
    final chart = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is FullChartPainter);
    expect(chart, findsOneWidget);
    final box = tester.getRect(chart);
    // Drag across: the reading follows the finger and stays after release.
    await tester.dragFrom(Offset(box.left + 50, box.center.dy), Offset(box.width * 0.4, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('La ora '), findsOneWidget);
    expect(tester.getSemantics(find.textContaining('La ora ')).flagsCollection.isLiveRegion, isTrue);
    // Scan the chart: the 160 ppm spike is found, and the gap reads "no data", never 0.
    final seen = <String>{};
    for (var x = box.left + 40; x < box.right - 4; x += 3) {
      await tester.tapAt(Offset(x, box.center.dy));
      await tester.pump();
      seen.add(tester.widget<Text>(find.textContaining('La ora ')).data!.split(': ').last);
    }
    expect(seen, containsAll(['160 ppm', '4 ppm', 'fără date']));
    expect(seen.any((v) => v.startsWith('0 ')), isFalse);

    // Swipe to the next measurement (gaz) outside the chart.
    await tester.fling(find.text('Ce înseamnă?'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Nivel gaz'), findsOneWidget);
    await tester.tap(find.byTooltip('Măsurătoarea anterioară'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Monoxid de carbon'), findsOneWidget);
  });

  testWidgets('chart page fits in landscape', (tester) async {
    phoneView(tester, textScale: 1.0);
    tester.view.physicalSize = const Size(800 * 3, 360 * 3);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);
    await openRoom(tester, 'Bucătărie');
    await _scrollHome(tester, find.text('Aer bucătărie'));
    await tester.tap(find.text('Aer bucătărie'));
    await settle(tester);
    // The sheet's test section comes first: scroll to the measurement tiles.
    final sheet = find.byType(Scrollable).last;
    final tile = find.descendant(of: sheet, matching: find.text('Temperatură ≈'));
    await tester.scrollUntilVisible(tile, 100, scrollable: sheet);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await settle(tester);
    expect(find.widgetWithText(AppBar, 'Temperatură ≈'), findsOneWidget);
  });

  testWidgets('home sketch: rooms placed, common area dashed, incident room "Evită", choice persisted',
      (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    const incident = Incident(
        id: 'i', buildingId: 'bld', hazardType: 'combustible_gas', severity: 'warning', state: 'verification',
        primaryZoneId: 'zone_kitchen');
    await tester.pumpWidget(ProviderScope(
      overrides: hubOverrides(storage, _hub(), incidents: const IncidentsState(incidents: [incident], connected: true)),
      child: const CanaryApp(),
    ));
    await settle(tester);
    await openAllSensors(tester);
    await _scrollHome(tester, find.text('Schiță'));
    expect(storage.homeStatusView, 'list');
    await tester.tap(find.text('Schiță'));
    await settle(tester);
    expect(storage.homeStatusView, 'sketch');

    await _scrollHome(tester, find.text('spațiu comun'));
    expect(find.text('Dormitor'), findsOneWidget);
    expect(find.text('Centrala'), findsOneWidget);
    expect(find.text('Evită'), findsOneWidget);
    // Relative layout: bedroom right of the kitchen, boiler below it.
    final kitchen = tester.getCenter(find.text('Bucătărie').last);
    final bedroom = tester.getCenter(find.text('Dormitor'));
    final boiler = tester.getCenter(find.text('Centrala'));
    expect(bedroom.dx, greaterThan(kitchen.dx));
    expect((bedroom.dy - kitchen.dy).abs(), lessThan(4));
    expect(boiler.dy, greaterThan(kitchen.dy));
    // The same facts are exposed to screen readers.
    expect(find.bySemanticsLabel(RegExp(r'^Bucătărie, Scurgere de gaz, .*2 senzori, Evită$')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Centrala, spațiu comun, ')), findsOneWidget);

    // Tap a room: its sensors; one opens the existing sensor sheet.
    await _scrollHome(tester, find.text('Dormitor'));
    await tester.tap(find.text('Dormitor'));
    await settle(tester);
    expect(find.text('Aer dormitor'), findsOneWidget);
    await tester.tap(find.text('Aer dormitor'));
    await settle(tester);
    expect(find.text('Măsurători'), findsOneWidget);
  });

  testWidgets('sketch is remembered', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage(extra: {'home_status_view': 'sketch'});
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);
    await openAllSensors(tester);
    await _scrollHome(tester, find.text('Dormitor'));
    expect(find.text('spațiu comun'), findsOneWidget);
  });
}
