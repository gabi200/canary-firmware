import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/models/check_in.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/dashboard_providers.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/locale_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers every request from [respond] and records what was sent.
class _FakeHub implements HttpClientAdapter {
  _FakeHub(this.respond);
  final Object Function(RequestOptions request) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(respond(options)), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Future<Storage> _storage([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return Storage(await SharedPreferences.getInstance());
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final _en = lookupAppLocalizations(const Locale('en'));
final _ro = lookupAppLocalizations(const Locale('ro'));

void main() {
  group('ARB catalogs', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync()) as Map<String, dynamic>;
    Set<String> keys(Map<String, dynamic> m) => m.keys.where((k) => !k.startsWith('@')).toSet();

    test('Romanian translates every English key', () {
      final en = arb('en');
      final ro = arb('ro');
      expect(keys(ro), keys(en));
      for (final k in keys(ro)) {
        expect((ro[k] as String).trim(), isNotEmpty, reason: k);
      }
    });

    test('Romanian uses comma-below ș ț, never cedilla ş ţ', () {
      const cedillas = ['ş', 'ţ', 'Ş', 'Ţ'];
      final sources = {
        'app_ro.arb': File('lib/l10n/app_ro.arb').readAsStringSync(),
        'safety_signs.dart': File('lib/src/logic/safety_signs.dart').readAsStringSync(),
      };
      for (final MapEntry(:key, :value) in sources.entries) {
        for (final c in cedillas) {
          expect(value.contains(c), isFalse, reason: '$key contains U+${c.codeUnitAt(0).toRadixString(16)}');
        }
      }
    });

    test('glossary terms', () {
      expect(_ro.evacuateNow, 'EVACUAȚI ACUM');
      expect(_ro.allClear, 'Totul e în regulă');
      expect(_ro.homeStatus, 'Starea locuinței');
      expect(_ro.hazardName('combustible_gas'), 'Scurgere de gaz');
      expect(_ro.hazardName('co'), 'Monoxid de carbon');
      expect(_ro.hazardName('water_leak'), 'Scurgere de apă');
      expect(_ro.checkInLabel(CheckInStatus.safeOutside), 'Am ieșit, sunt în siguranță');
      expect(_ro.checkInLabel(CheckInStatus.needsHelp), 'Am nevoie de ajutor');
      expect(_ro.linkMyUnit, 'Conectează-mi apartamentul');
      expect(_ro.checkInSent('x'), 'Confirmare trimisă: x');
    });
  });

  group('labels', () {
    test('unknown backend tokens fall back to the token', () {
      expect(_ro.hazardName('radon'), 'radon');
      expect(_ro.statusLabel('false_alarm'), 'alarmă falsă');
      expect(_ro.statusLabel('brand_new_state'), 'brand new state');
      expect(_en.roleName('hoa_manager'), 'Building manager');
    });

    test('Romanian plurals', () {
      expect(_ro.checkInsQueued(1), 'O confirmare în așteptare');
      expect(_ro.checkInsQueued(3), '3 confirmări în așteptare');
      expect(_ro.checkInsQueued(20), '20 de confirmări în așteptare');
      expect(_ro.sensorsOnline(5, 6), '5 din 6 senzori online');
      expect(_ro.sensorsOnline(1, 1), '1 din 1 senzor online');
      expect(_en.sensorsOnline(6, 6), '6 of 6 sensors online');
      expect(_en.activeIncidentCount(1), '1 active incident');
    });

    test('relative and clock times use the active locale', () async {
      await initializeDateFormatting('ro');
      await initializeDateFormatting('en');
      final now = DateTime(2026, 10, 9, 21, 40);
      expect(_ro.timeAgo(now.subtract(const Duration(seconds: 20)), now: now), 'chiar acum');
      expect(_ro.timeAgo(now.subtract(const Duration(minutes: 5)), now: now), 'acum 5 min');
      expect(_ro.timeAgo(now.subtract(const Duration(hours: 1)), now: now), 'acum o oră');
      expect(_en.timeAgo(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(_ro.clockTime(DateTime(2026, 10, 9, 8, 5), now: now), '08:05');
      expect(_ro.clockTime(DateTime(2026, 10, 8, 21, 40), now: now), contains('oct.'));
      expect(_ro.count(1234), '1.234');
      expect(_en.count(1234), '1,234');
    });

    test('incident notifications are built in the app language', () {
      const evac = Incident(
        id: 'i', buildingId: 'b', hazardType: 'combustible_gas', severity: 'critical', state: 'evacuation');
      expect(_ro.incidentAlert(evac).title, 'EVACUAȚI ACUM — Scurgere de gaz');
      expect(_en.incidentAlert(evac).title, 'EVACUATE NOW — Gas leak');
    });

    test('request errors: server detail as sent, else localized', () {
      expect(_ro.errorReason(ApiException('x')), _ro.serverUnreachable);
      expect(_ro.errorReason(ApiException('x', statusCode: 500)), 'Eroare de server (500)');
      expect(_ro.errorReason(ApiException('x', statusCode: 404, detail: 'Unknown user')), 'Unknown user');
    });
  });

  group('language choice', () {
    test('device default: Romanian only when the device prefers Romanian', () {
      expect(deviceLanguageCode(const [Locale('ro', 'RO')]), 'ro');
      expect(deviceLanguageCode(const [Locale('en', 'US'), Locale('ro')]), 'en');
      expect(deviceLanguageCode(const [Locale('de')]), 'en');
      expect(deviceLanguageCode(const []), 'en');
    });

    test('a saved choice wins over the device and persists', () async {
      final storage = await _storage({'language': 'en'});
      expect(initialLanguageCode(storage, const [Locale('ro')]), 'en');

      final controller = LocaleController(storage, deviceLocales: const [Locale('ro')]);
      expect(controller.state.languageCode, 'en');
      await controller.setLanguage('ro');
      expect(controller.state, const Locale('ro'));
      expect(storage.languageCode, 'ro');
      await controller.setLanguage('fr'); // unsupported: ignored
      expect(controller.state, const Locale('ro'));
    });

    test('nothing saved: follows the device', () async {
      final storage = await _storage();
      expect(LocaleController(storage, deviceLocales: const [Locale('ro', 'MD')]).state.languageCode, 'ro');
      expect(storage.languageCode, isNull);
    });
  });

  group('Accept-Language', () {
    test('ApiClient sends the language current at request time', () async {
      final hub = _FakeHub((_) => const <Object>[]);
      var lang = 'ro';
      final api = ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'http://hub.test'))..httpClientAdapter = hub,
        languageCode: () => lang,
      );
      await api.activeIncidents('bld');
      lang = 'en';
      await api.activeIncidents('bld');
      expect(hub.requests.map((r) => r.headers['Accept-Language']), ['ro', 'en']);
    });

    test('a language switch refetches the summary and dashboard in the new language', () async {
      final storage = await _storage({
        'language': 'en',
        'session': jsonEncode(const AuthSession(
          token: 't', userId: 'u', role: 'hoa_manager', username: 'm', buildingId: 'bld').toJson()),
      });
      final hub = _FakeHub((r) {
        final ro = r.headers['Accept-Language'] == 'ro';
        if (r.path.endsWith('/summary')) {
          return {'building_id': 'bld', 'status': 'ok', 'headline': ro ? 'Aerul e bun' : 'Air is good', 'zones': []};
        }
        return {'incident_id': 'inc', 'occupancy_total': 2, 'accounted': 1, 'unaccounted': 1, 'needs_help': 0};
      });
      final container = ProviderContainer(overrides: [
        storageProvider.overrideWithValue(storage),
        apiClientProvider.overrideWith((ref) => ApiClient(
              dio: Dio(BaseOptions(baseUrl: 'http://hub.test'))..httpClientAdapter = hub,
              languageCode: () => ref.read(languageCodeProvider),
            )),
        // Idle incident controller: no WebSocket in tests.
        incidentControllerProvider.overrideWith(
          (ref) => IncidentController(ref.watch(apiClientProvider), storage, null)),
      ]);
      addTearDown(container.dispose);
      container.listen(summaryProvider, (_, __) {});
      container.listen(accountingProvider('inc'), (_, __) {});
      await _settle();
      expect(container.read(summaryProvider).summary?.headline, 'Air is good');

      await container.read(localeProvider.notifier).setLanguage('ro');
      await _settle();
      expect(container.read(summaryProvider).summary?.headline, 'Aerul e bun');
      final langs = {
        for (final path in ['/summary', '/accounting'])
          path: hub.requests.where((r) => r.path.endsWith(path)).map((r) => r.headers['Accept-Language']).toList(),
      };
      expect(langs['/summary'], ['en', 'ro']);
      expect(langs['/accounting'], ['en', 'ro']);
    });
  });

  testWidgets('onboarding follows the saved language and the RO / EN toggle', (tester) async {
    final storage = await _storage({'language': 'ro'});
    await tester.pumpWidget(ProviderScope(
      overrides: [storageProvider.overrideWithValue(storage)],
      child: const CanaryApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Conectează-mi apartamentul'), findsOneWidget);
    expect(find.text('Utilizator'), findsOneWidget);
    expect(find.text('ID clădire'), findsOneWidget);

    await tester.tap(find.text('EN'));
    await tester.pumpAndSettle();
    expect(find.text('Link my unit'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(storage.languageCode, 'en');
  });
}
