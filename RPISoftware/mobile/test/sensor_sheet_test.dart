// Room vitals + sensor sheet in Romanian at 360 dp with large text (1.3): big
// readings, plain words, gaps for warming-up readings, no overflow.
import 'dart:convert';

import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_hub.dart';

/// The hub, with an air and a water sensor in the kitchen.
class _Hub implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  bool failHistory = false;

  Map<String, Object?> _summary() {
    final now = DateTime.now().toUtc().toIso8601String();
    return {
      'building_id': 'bld', 'status': 'ok', 'headline': 'Totul e în regulă',
      'nodes_total': 2, 'nodes_online': 2, 'active_incidents': 0,
      'zones': [
        {
          'zone_id': 'zone_kitchen', 'zone_label': 'Bucătărie', 'status': 'ok', 'occupied': null,
          'nodes': [
            {
              'node_id': 'air-kitchen', 'kind': 'air', 'name': 'Aer bucătărie', 'online': true, 'stale': false,
              'last_seen_ts': now, 'status': 'ok', 'headline': 'Calitatea aerului e bună',
              'indicators': [
                {'key': 'air_quality', 'label': 'Calitatea aerului', 'level': 'ok', 'value': 'Bună', 'detail': 'AQI 39'},
                {'key': 'co', 'label': 'Monoxid de carbon', 'level': 'ok', 'value': 'Sigur'},
              ],
            },
            {
              'node_id': 'water-kitchen', 'kind': 'water', 'name': 'Apă bucătărie', 'online': true, 'stale': false,
              'last_seen_ts': now, 'status': 'ok', 'headline': 'Nicio scurgere',
              'indicators': [
                {'key': 'leak', 'label': 'Scurgere de apă', 'level': 'ok', 'value': 'Nicio scurgere'},
                {'key': 'valve', 'label': 'Robinet de apă', 'level': 'ok', 'value': 'Deschis'},
              ],
            },
          ],
        },
      ],
    };
  }

  Map<String, Object?> _history(RequestOptions r) {
    final minutes = int.parse('${r.queryParameters['minutes']}');
    final now = DateTime.now().toUtc();
    final water = r.path.contains('water-');
    // One point a minute keeps the body under Dio's 50 KB background-decode
    // limit (an isolate would never finish under the test's fake clock).
    const step = Duration(minutes: 1);
    final n = (const Duration(minutes: 40).inSeconds / step.inSeconds).round();
    return {
      'node_id': water ? 'water-kitchen' : 'air-kitchen',
      'minutes': minutes,
      'fields': '${r.queryParameters['fields']}'.split(','),
      'points': [
        for (var i = 0; i < n; i++)
          {
            'ts': now.subtract(step * (n - 1 - i)).toIso8601String(),
            'values': water
                ? {
                    // A short leak 20 minutes ago, dry since.
                    'leak_latched': (n - 1 - i) >= 19 && (n - 1 - i) <= 20 ? 1 : 0,
                    'sensor.adc': 330, 'sensor.wet_threshold': 1200,
                  }
                : {
                    'climate.temperature_c': i == n - 1 ? 22.4 : (i.isEven ? 21.1 : 23.0),
                    // Humidity warming up: newest reading invalid, plus a gap.
                    'climate.humidity_percent': i == n - 1 || i == 5 ? null : 41.5,
                    'particulate.pm2_5': 7, 'particulate.pm10': 9,
                    'co.ppm': 3, 'gas.adc': 682,
                    'co.warn_ppm': 50, 'co.danger_ppm': 100, 'gas.warn_adc': 1500,
                    'particulate.warn_pm2_5': 35, 'particulate.danger_pm2_5': 150,
                    'particulate.warn_pm10': 100, 'particulate.danger_pm10': 250,
                  },
          },
      ],
    };
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final path = options.path;
    if (path.endsWith('/history') && failHistory) {
      return ResponseBody.fromString('{"detail":"boom"}', 500, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });
    }
    final Object body = path.endsWith('/summary')
        ? _summary()
        : path.endsWith('/history')
            ? _history(options)
            : path.endsWith('/incidents')
                ? const <Object>[]
                : const <String, Object>{};
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

class _NoIncidents extends IncidentController {
  _NoIncidents(ApiClient api, Storage storage) : super(api, storage, null) {
    state = const IncidentsState(connected: true);
  }
}

Future<_Hub> _pumpHome(WidgetTester tester, {String language = 'ro'}) async {
  tester.view.physicalSize = const Size(360 * 3, 760 * 3);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);

  SharedPreferences.setMockInitialValues({
    'language': language,
    'session': jsonEncode(const AuthSession(
      token: 't', userId: 'u', role: 'resident', username: 'ana', buildingId: 'bld').toJson()),
  });
  final storage = Storage(await SharedPreferences.getInstance());
  final hub = _Hub();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      storageProvider.overrideWithValue(storage),
      hubFound(storage),
      apiClientProvider.overrideWith((ref) => ApiClient(
            dio: Dio(BaseOptions(baseUrl: 'http://hub.test'))..httpClientAdapter = hub,
            languageCode: () => ref.read(languageCodeProvider),
          )),
      incidentControllerProvider.overrideWith((ref) => _NoIncidents(ref.watch(apiClientProvider), storage)),
    ],
    child: const CanaryApp(),
  ));
  await _settle(tester);
  return hub;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the kitchen from its tile on home, scrolls its page until [finder] is
/// on screen, then lets fetches land.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await openRoom(tester, 'Bucătărie');
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(finder);
  await _settle(tester);
}

Iterable<RequestOptions> _historyCalls(_Hub hub, String node) =>
    hub.requests.where((r) => r.path.endsWith('/nodes/$node/history'));

void main() {
  testWidgets('room card shows big vitals; air sheet tiles in Romanian at 1.3x text', (tester) async {
    final hub = await _pumpHome(tester);

    // Room card vitals (latest reading; humidity's newest reading is invalid).
    await _reveal(tester, find.text('Aer bucătărie'));
    expect(find.text('Temperatură ≈'), findsOneWidget);
    expect(find.text('Se încălzește'), findsOneWidget);
    expect(find.text('Fără scurgeri'), findsOneWidget);
    expect(find.text('Bună'), findsOneWidget);
    expect(find.bySemanticsLabel('Temperatură aproximativ 22,4 grade'), findsOneWidget);
    // Only the visible air node's climate is fetched for the card.
    expect(_historyCalls(hub, 'air-kitchen').single.queryParameters['minutes'], 15);
    expect(_historyCalls(hub, 'water-kitchen'), isEmpty);

    await tester.tap(find.text('Aer bucătărie'));
    await _settle(tester);

    expect(find.text('Măsurători'), findsOneWidget);
    expect(find.text('1h'), findsOneWidget);
    expect(find.text('7z'), findsOneWidget);
    expect(_historyCalls(hub, 'air-kitchen').last.queryParameters['minutes'], 60);
    expect(find.text('Temperatură ≈'), findsNWidgets(2)); // card chip + sheet tile
    expect(find.bySemanticsLabel(RegExp(
        r'^Temperatură: aproximativ 22,4 grade, Confortabil\. Între 21,1 și 23,0 în ultima oră\.$')), findsOneWidget);
    expect(find.text('21,1 – 23,0 °C'), findsOneWidget);
    expect(find.text('Confortabil'), findsOneWidget);
    expect(find.text('Umiditate ≈'), findsNWidgets(2));
    expect(find.text('Particule fine (PM2.5)'), findsOneWidget);

    final sheet = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(find.text('Nivel gaz'), 150, scrollable: sheet);
    expect(find.text('din pragul de alertă'), findsOneWidget);
    expect(find.text('Monoxid de carbon'), findsWidgets);
    expect(find.text('Sigur'), findsWidgets);
    expect(find.text('Normal'), findsOneWidget); // gas 45 % of warning
    expect(find.bySemanticsLabel(RegExp(r'^Nivel gaz: 45 la sută din pragul de alertă, Normal\.')), findsOneWidget);

    // Last 24 hours.
    await tester.scrollUntilVisible(find.text('24h'), -150, scrollable: sheet);
    await tester.tap(find.text('24h'));
    await _settle(tester);
    expect(_historyCalls(hub, 'air-kitchen').last.queryParameters['minutes'], 1440);
    expect(find.bySemanticsLabel(RegExp(r'în ultimele 24 de ore\.$')), findsWidgets);
  });

  testWidgets('water sheet: dry / leak timeline, last leak, valve; history error + retry', (tester) async {
    final hub = await _pumpHome(tester);
    await _reveal(tester, find.text('Apă bucătărie'));
    await tester.tap(find.text('Apă bucătărie'));
    await _settle(tester);

    expect(find.text('Scurgere'), findsOneWidget);
    expect(find.text('Uscat'), findsOneWidget);
    expect(find.textContaining('Ultima scurgere: '), findsOneWidget);
    expect(find.text('Robinet'), findsOneWidget);
    expect(find.text('Deschis'), findsOneWidget);

    // History fails: an error line with retry; retry recovers.
    hub.failHistory = true;
    await tester.tap(find.text('7z'));
    await _settle(tester);
    expect(find.text('Măsurătorile nu au putut fi încărcate.'), findsOneWidget);
    hub.failHistory = false;
    await tester.tap(find.text('Reîncearcă'));
    await _settle(tester);
    expect(find.text('Măsurătorile nu au putut fi încărcate.'), findsNothing);
    expect(find.text('Nicio scurgere în ultimele 7 zile'), findsNothing); // there was a leak
    expect(find.textContaining('Ultima scurgere: '), findsOneWidget);
  });

  testWidgets('English sheet', (tester) async {
    await _pumpHome(tester, language: 'en');
    await _reveal(tester, find.text('Aer bucătărie'));
    expect(find.text('Temperature ≈'), findsOneWidget);
    expect(find.text('Warming up'), findsOneWidget);
    expect(find.text('No leaks'), findsOneWidget);
    await tester.tap(find.text('Aer bucătărie'));
    await _settle(tester);
    expect(find.text('Measurements'), findsOneWidget);
    expect(find.text('7d'), findsOneWidget);
    expect(find.text('21.1 – 23.0 °C'), findsOneWidget);
    expect(find.text('Comfortable'), findsOneWidget);
  });
}
