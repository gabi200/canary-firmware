// Live-test fixes: building status never says "all clear" while an incident is
// open; the room "Air" chip shows the worst air indicator; alarm-screen button
// labels never wrap; sparklines turn amber / red above their limits.
import 'dart:ui' as ui;

import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/logic/sensor_series.dart';
import 'package:canary_resident/src/models/history.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/models/summary.dart';
import 'package:canary_resident/src/state/building_status.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/state/summary_controller.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:canary_resident/src/ui/widgets/sensor_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

const _verifying = Incident(
  id: 'inc', buildingId: 'bld', hazardType: 'combustible_gas', severity: 'warning',
  state: 'verification', primaryZoneId: 'zone_kitchen',
);

BuildingSummary _summary(String status, {int incidents = 0, String headline = ''}) => BuildingSummary.fromJson({
      'building_id': 'bld', 'status': status, 'headline': headline, 'active_incidents': incidents, 'zones': [],
    });

Map<String, Object?> _summaryJson({String gas = 'attention', String co = 'ok'}) => {
      'building_id': 'bld', 'status': 'attention', 'headline': 'Scurgere de gaz — verificare',
      'nodes_total': 1, 'nodes_online': 1, 'active_incidents': 1,
      'zones': [
        {
          'zone_id': 'zone_kitchen', 'zone_label': 'Bucătărie', 'status': 'attention',
          'nodes': [
            {
              'node_id': 'air-kitchen', 'kind': 'air', 'name': 'Kitchen air', 'online': true, 'stale': false,
              'last_seen_ts': DateTime.now().toUtc().toIso8601String(), 'status': 'attention',
              'headline': 'Nivel ridicat de gaz',
              'indicators': [
                {'key': 'air_quality', 'label': 'Calitatea aerului', 'level': 'ok', 'value': 'Bună'},
                {'key': 'co', 'label': 'Monoxid de carbon', 'level': co, 'value': 'x'},
                {'key': 'gas', 'label': 'Gaz combustibil', 'level': gas, 'value': 'Nivel ridicat'},
              ],
            },
          ],
        },
      ],
    };

void main() {
  group('building status', () {
    SummaryState s(BuildingSummary? summary, {String? error}) => SummaryState(summary: summary, error: error);

    test('an open, non-alarming incident is "verifying", never all clear', () {
      final st = buildingStatusOf(const IncidentsState(incidents: [_verifying]), s(_summary('ok')));
      expect(st.kind, BuildingStatusKind.verifying);
      expect(st.pillState, 'verification');
    });

    test('alarm wins; hub status decides when no incident', () {
      const alarm = Incident(id: 'a', buildingId: 'b', hazardType: 'co', severity: 'critical', state: 'alarm');
      expect(buildingStatusOf(const IncidentsState(incidents: [_verifying, alarm]), s(null)).kind,
          BuildingStatusKind.alarm);
      expect(buildingStatusOf(const IncidentsState(), s(_summary('attention'))).kind, BuildingStatusKind.attention);
      expect(buildingStatusOf(const IncidentsState(), s(_summary('danger'))).kind, BuildingStatusKind.danger);
      expect(buildingStatusOf(const IncidentsState(), s(_summary('ok', incidents: 1))).kind,
          BuildingStatusKind.attention, reason: 'hub knows of an incident the list lacks');
      expect(buildingStatusOf(const IncidentsState(), s(_summary('ok'))).kind, BuildingStatusKind.clear);
      expect(buildingStatusOf(const IncidentsState(), s(null)).kind, BuildingStatusKind.loading);
      final down = buildingStatusOf(const IncidentsState(), s(null, error: 'x'));
      expect([down.kind, down.unreachable], [BuildingStatusKind.unknown, true]);
    });
  });

  group('room "Air" chip', () {
    NodeAnalysis node({String aq = 'ok', String co = 'ok', String gas = 'ok'}) => NodeAnalysis.fromJson({
          'node_id': 'n', 'kind': 'air', 'online': true, 'status': 'ok',
          'indicators': [
            {'key': 'air_quality', 'level': aq, 'value': 'Bună'},
            {'key': 'co', 'level': co, 'value': 'Sigur'},
            {'key': 'gas', 'level': gas, 'value': 'Sigur'},
          ],
        });

    test('worst of air quality, CO and gas', () {
      expect(airChipState(node())!.source, 'air_quality');
      expect(airChipState(node(gas: 'attention'))!.source, 'gas');
      expect(airChipState(node(gas: 'attention'))!.tone, Tone.attention);
      expect(airChipState(node(gas: 'attention', co: 'danger'))!.source, 'co');
      expect(airChipState(node(gas: 'danger', co: 'attention'))!.source, 'gas');
      expect(airChipState(node(gas: 'danger', co: 'danger'))!.source, 'co', reason: 'CO wins a tie');
      expect(airChipState(node(aq: 'attention', gas: 'unknown'))!.source, 'air_quality');
    });
  });

  testWidgets('home during verification: amber card + pill, no alarm screen, chip shows gas', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = FakeHub()
      ..reply('GET /api/v1/buildings/bld/summary', 200, _summaryJson())
      ..reply('GET /api/v1/buildings/bld/zones', 200, [
        {'id': 'zone_kitchen', 'label': 'Bucătărie', 'unit_id': 'unit_0312'},
      ])
      ..reply('GET /api/v1/me/care-profiles', 200, const []);
    await tester.pumpWidget(ProviderScope(
      overrides: hubOverrides(storage, hub, incidents: const IncidentsState(incidents: [_verifying], connected: true)),
      child: const CanaryApp(),
    ));
    await settle(tester);

    expect(find.text('Se verifică o posibilă problemă'), findsOneWidget);
    expect(find.text('Scurgere de gaz · Bucătărie'), findsOneWidget);
    expect(find.text('Încă nu e nevoie să ieși. Te anunțăm imediat dacă trebuie.'), findsOneWidget);
    expect(find.text('Totul e în regulă'), findsNothing);
    expect(find.text('TOTUL E ÎN REGULĂ'), findsNothing);
    expect(find.byType(AlarmScreen), findsNothing);
    expect(find.text('Cineva din casă are nevoie de ajutor să iasă?'), findsNothing);
    await tester.scrollUntilVisible(find.text('VERIFICARE'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Clădirea: Scurgere de gaz'), findsOneWidget);

    await openRoom(tester, 'Bucătărie');
    await tester.scrollUntilVisible(find.text('Kitchen air'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Gaz ridicat'), findsOneWidget);
    expect(find.text('Bună'), findsNothing);
  });

  for (final (width, scale) in [(360.0, 1.3), (430.0, 1.0), (430.0, 1.3)]) {
    testWidgets('alarm bar labels stay on one line at ${width.toInt()} dp x$scale', (tester) async {
      phoneView(tester, textScale: scale);
      tester.view.physicalSize = Size(width * 3, 860 * 3);
      final storage = await signedInStorage();
      final hub = FakeHub()
        ..reply('GET /api/v1/buildings/bld/evacuation', 200, {'routes': [], 'assembly_points': []})
        ..reply('GET /api/v1/me/care-profiles', 200, const []);
      const incident = Incident(
          id: 'inc', buildingId: 'bld', hazardType: 'combustible_gas', severity: 'critical', state: 'evacuation');
      await tester.pumpWidget(ProviderScope(
        overrides: hubOverrides(storage, hub, incidents: const IncidentsState(incidents: [incident], connected: true)),
        child: Consumer(builder: (context, ref, _) => MaterialApp(
              locale: ref.watch(localeProvider),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const AlarmScreen(incidentId: 'inc'),
            )),
      ));
      await settle(tester);

      for (final label in ['Am ieșit, sunt în siguranță', 'Am nevoie de ajutor', 'Sună la 112', 'Sunt bine, dar încă înăuntru']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
        final oneLine = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: label.length))
            .map((b) => b.top.round())
            .toSet();
        expect(oneLine, hasLength(1), reason: '"$label" wrapped');
      }
    });
  }

  testWidgets('sparkline: the part above the danger limit is drawn red', (tester) async {
    final t0 = DateTime.utc(2026, 10, 9, 20);
    final history = NodeHistory.fromJson({
      'node_id': 'n', 'minutes': 60,
      'points': [
        for (var i = 0; i < 60; i++)
          {'ts': t0.add(Duration(minutes: i)).toIso8601String(), 'values': {'co': (i >= 25 && i < 35) ? 160 : 4}},
      ],
    }, now: t0.add(const Duration(minutes: 60)));
    final series = Series.of(history, 'co');

    Future<ui.Color> pixelAtSpike({required bool limits}) async {
      final key = GlobalKey();
      await tester.pumpWidget(Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 120,
            height: 40,
            child: CustomPaint(
              painter: SparklinePainter(
                series: series,
                maxGap: const Duration(minutes: 2),
                color: HazardColorsForTest.green,
                threshold: limits ? 50 : null,
                amberFrom: limits ? 50 : null,
                redFrom: limits ? 100 : null,
              ),
            ),
          ),
        ),
      ));
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!;
      });
      // Middle of the 160 ppm plateau (x = 30 / 60 of 120 px), on its stroke.
      final bounds = chartBounds(series, threshold: limits ? 50 : null);
      final y = (40 - 1 - (160 - bounds.min) / (bounds.max - bounds.min) * 38).round();
      final offset = (y * 120 + 60) * 4;
      return ui.Color.fromARGB(255, bytes!.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
    }

    final plain = await pixelAtSpike(limits: false);
    final limited = await pixelAtSpike(limits: true);
    expect((plain.g * 255).round(), greaterThan((plain.r * 255).round()), reason: 'green without limits');
    expect((limited.r * 255).round(), greaterThan(150));
    expect((limited.g * 255).round(), lessThan(100), reason: 'red above the danger limit');
  });
}

abstract final class HazardColorsForTest {
  static const green = Color(0xFF2E7D32);
}
