// Screens rendered in Romanian at phone width: the strings are wired, the longer
// Romanian copy lays out without overflow, and a switch to English applies live.
import 'dart:convert';

import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_hub.dart' show hubFound, openAllSensors;

class _FakeHub implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  Object _respond(RequestOptions r) {
    final path = r.path;
    if (path.endsWith('/summary')) {
      final seen = DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String();
      return {
        'building_id': 'bld', 'status': 'attention', 'headline': 'Verifică bucătăria',
        'nodes_total': 6, 'nodes_online': 5, 'active_incidents': 1,
        'zones': [
          {
            'zone_id': 'zone_kitchen', 'zone_label': 'Bucătărie', 'status': 'attention', 'occupied': true,
            'nodes': [
              {
                'node_id': 'n1', 'kind': 'air', 'name': 'Aer bucătărie', 'online': false, 'stale': true,
                'last_seen_ts': seen, 'status': 'unknown', 'headline': '',
                'indicators': [
                  {'key': 'co', 'label': '', 'level': 'unknown', 'value': '—', 'trend': 'rising'},
                ],
              },
            ],
          },
        ],
      };
    }
    if (path.endsWith('/evacuation')) {
      return {
        'assembly_points': [
          {'id': 'ap', 'label': 'Curtea din față'},
        ],
        'routes': [
          {
            'id': 'r1', 'label': '', 'path': ['zone_hall', 'stairs', 'ap'],
            'to_assembly_point_id': 'ap', 'from_zone_id': 'zone_hall',
            'waypoints': [
              {'id': 'zone_hall', 'label': 'Hol'},
              {'id': 'stairs', 'label': 'Scara principală', 'hint': 'Coboară la parter'},
              {'id': 'ap', 'label': 'Curtea din față', 'kind': 'assembly_point'},
            ],
          },
        ],
      };
    }
    if (path.endsWith('/zones')) {
      return [
        {'id': 'zone_kitchen', 'label': 'Bucătărie'},
      ];
    }
    if (path.endsWith('/accounting')) {
      return {'incident_id': 'inc', 'occupancy_total': 12, 'accounted': 9, 'unaccounted': 3, 'needs_help': 1};
    }
    if (path.endsWith('/roster')) {
      return {
        'incident_id': 'inc', 'total': 1, 'safe': 0, 'needs_help': 1, 'awaiting': 0,
        'entries': [
          {'user_id': 'u1', 'display_name': 'Ana Popescu', 'status': 'needs_help', 'unit_label': 'Ap. 4'},
        ],
      };
    }
    return <String, Object>{};
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(_respond(options)), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Incident list without a WebSocket.
class _Incidents extends IncidentController {
  _Incidents(ApiClient api, Storage storage, List<Incident> incidents) : super(api, storage, null) {
    state = IncidentsState(incidents: incidents, connected: true);
  }
}

const _gasEvacuation = Incident(
  id: 'inc', buildingId: 'bld', hazardType: 'combustible_gas', severity: 'critical',
  state: 'evacuation', primaryZoneId: 'zone_kitchen',
);

Future<(Storage, _FakeHub, List<Override>)> _setUp(WidgetTester tester, {required String role}) async {
  tester.view.physicalSize = const Size(360 * 3, 760 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  // Haptics / wakelock / dialer have no platform side in tests.
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  messenger.setMockMessageHandler(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]),
  );

  SharedPreferences.setMockInitialValues({
    'language': 'ro',
    'session': jsonEncode(AuthSession(
      token: 't', userId: 'u', role: role, username: 'ana', buildingId: 'bld').toJson()),
  });
  final storage = Storage(await SharedPreferences.getInstance());
  final hub = _FakeHub();
  return (
    storage,
    hub,
    <Override>[
      storageProvider.overrideWithValue(storage),
      hubFound(storage),
      apiClientProvider.overrideWith((ref) => ApiClient(
            dio: Dio(BaseOptions(baseUrl: 'http://hub.test'))..httpClientAdapter = hub,
            languageCode: () => ref.read(languageCodeProvider),
          )),
      incidentControllerProvider.overrideWith(
        (ref) => _Incidents(ref.watch(apiClientProvider), storage, const [_gasEvacuation])),
    ],
  );
}

Future<void> _pumpFor(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('alarm screen in Romanian, check-in snackbar included', (tester) async {
    final (_, _, overrides) = await _setUp(tester, role: 'resident');
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: Consumer(builder: (context, ref, _) => MaterialApp(
        locale: ref.watch(localeProvider),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const AlarmScreen(incidentId: 'inc'),
      )),
    ));
    await _pumpFor(tester);

    expect(find.text('EVACUAȚI ACUM'), findsOneWidget);
    // A zone without a unit or floor: named, but not relative to the resident.
    expect(find.text('În clădire: Bucătărie'), findsOneWidget);
    expect(find.text('Nu folosi liftul, întrerupătoarele sau flacăra deschisă.'), findsOneWidget);
    expect(find.text('Unde ești acum?'), findsOneWidget);
    expect(find.text('În altă parte în clădire'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Traseu de evacuare'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Traseu de evacuare'), findsOneWidget);
    expect(find.text('Începe aici'), findsOneWidget);
    expect(find.text('Evită: Bucătărie'), findsOneWidget);
    expect(find.text('Hol'), findsOneWidget); // building data shown as sent
    expect(find.text('Minimizează'), findsOneWidget);
    expect(find.text('Sună la 112'), findsOneWidget);
    expect(find.text('Am nevoie de ajutor'), findsOneWidget);
    expect(find.text('Sunt bine, dar încă înăuntru'), findsOneWidget);

    await tester.tap(find.text('Am ieșit, sunt în siguranță'));
    await _pumpFor(tester);
    expect(find.text('Confirmare trimisă: Am ieșit, sunt în siguranță'), findsOneWidget);
    expect(find.text('Confirmat: Am ieșit, sunt în siguranță'), findsOneWidget);
    // Out and safe also answers "Unde ești acum?"; both can be changed.
    expect(find.text('Ești: Afară'), findsOneWidget);
    expect(find.text('Schimbă'), findsNWidgets(2));
  });

  testWidgets('resident home + settings in Romanian, switching to English live', (tester) async {
    final (storage, hub, overrides) = await _setUp(tester, role: 'resident');
    await tester.pumpWidget(ProviderScope(overrides: overrides, child: const CanaryApp()));
    await _pumpFor(tester);

    // Status first: the danger, where it is, the way into the alarm screen.
    expect(find.text('EVACUAȚI ACUM'), findsOneWidget);
    expect(find.text('În clădire: Bucătărie'), findsOneWidget);
    expect(find.text('Deschide instrucțiunile de evacuare'), findsOneWidget);
    expect(find.text('Camerele mele'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Clădirea: Scurgere de gaz'), 200);
    expect(find.text('Scurgere de gaz'), findsOneWidget); // the kitchen tile
    expect(find.text('EVACUARE'), findsOneWidget);

    // The full sensor list, one tap away.
    await openAllSensors(tester);
    expect(find.text('Starea locuinței'), findsOneWidget);
    expect(find.text('Verifică bucătăria'), findsOneWidget); // hub headline as sent
    expect(find.text('5 din 6 senzori online · 1 incident activ'), findsOneWidget);
    expect(find.text('Deconectat · ultimul semnal acum 5 min'), findsOneWidget);
    expect(find.text('OCUPAT'), findsOneWidget);
    await tester.tap(find.byType(BackButton)); // pageBack() looks for the English tooltip
    await _pumpFor(tester);

    await tester.tap(find.byTooltip('Setări'));
    await _pumpFor(tester);
    expect(find.text('Setări'), findsOneWidget);
    expect(find.text('LIMBĂ'), findsOneWidget);
    expect(find.text('Locatar · bld'), findsOneWidget);

    final summaryCalls = hub.requests.where((r) => r.path.endsWith('/summary')).length;
    await tester.tap(find.text('EN'));
    await _pumpFor(tester);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Resident · bld'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    expect(find.text('Sign out'), findsOneWidget);
    expect(storage.languageCode, 'en');
    final summaryLangs =
        hub.requests.where((r) => r.path.endsWith('/summary')).map((r) => r.headers['Accept-Language']);
    expect(summaryLangs.length, greaterThan(summaryCalls));
    expect(summaryLangs.last, 'en');

    await tester.pageBack();
    await _pumpFor(tester);
    // Still scrolled to the building strip.
    expect(find.text('Building: Gas leak'), findsOneWidget);
    expect(find.text('In the building: Bucătărie'), findsWidgets);
    expect(find.text('EVACUATION'), findsOneWidget);
  });

  testWidgets('manager dashboard in Romanian', (tester) async {
    final (_, _, overrides) = await _setUp(tester, role: 'hoa_manager');
    await tester.pumpWidget(ProviderScope(overrides: overrides, child: const CanaryApp()));
    await _pumpFor(tester);

    expect(find.text('EVACUAȚI ACUM'), findsOneWidget);
    expect(find.text('Scurgere de gaz · Bucătărie'), findsOneWidget);
    expect(find.text('Evidența ocupanților'), findsOneWidget);
    expect(find.text('Neconfirmați'), findsOneWidget);
    expect(find.text('Au nevoie de ajutor'), findsOneWidget);
    expect(find.text('Ordonă evacuarea'), findsOneWidget);
    expect(find.text('Situația locatarilor'), findsOneWidget);
    expect(find.text('ARE NEVOIE DE AJUTOR'), findsOneWidget);
    expect(find.text('Ana Popescu'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Senzorii clădirii'), 200);
    expect(find.text('Senzorii clădirii'), findsOneWidget);
  });
}
