// Apple Health import: the needs mapping (pure) and the suggestion card in the
// care form (fake HealthKit). Plus the hub language sync.
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/logic/health_suggestions.dart';
import 'package:canary_resident/src/models/care_profile.dart';
import 'package:canary_resident/src/services/health_import.dart';
import 'package:canary_resident/src/state/care_providers.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/care_profiles_screen.dart';
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

List<AudiogramPoint> _audiogram({required double left, required double right, bool skip2k = false}) => [
      for (final hz in [250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0])
        if (!(skip2k && hz == 2000))
          AudiogramPoint(hz: hz, left: left, right: right),
    ];

class _FakeHealth extends HealthImport {
  _FakeHealth(this.reading, {this.fail = false});
  final HealthReading reading;
  final bool fail;
  int reads = 0;

  @override
  bool get supported => true;

  @override
  Future<HealthReading> read() async {
    reads++;
    if (fail) throw StateError('denied');
    return reading;
  }
}

void main() {
  group('Health → suggested needs', () {
    test('wheelchair use from the Health profile', () {
      expect(healthSuggestions(const HealthReading(wheelchairUse: 'yes')).single.need, CareNeed.wheelchair);
      expect(healthSuggestions(const HealthReading(wheelchairUse: 'no')), isEmpty);
      expect(healthSuggestions(const HealthReading(wheelchairUse: 'notSet')), isEmpty);
    });

    test('walking steadiness below 40 % (Low / Very low)', () {
      expect(healthSuggestions(const HealthReading(walkingSteadiness: 0.399)).single.need, CareNeed.reducedMobility);
      expect(healthSuggestions(const HealthReading(walkingSteadiness: 0.40)), isEmpty);
      expect(healthSuggestions(const HealthReading(walkingSteadiness: 0.85)), isEmpty);
      expect(healthSuggestions(const HealthReading(walkingSteadiness: 0.25)).single.value, closeTo(25, 1e-9));
    });

    test('audiogram: better-ear average over 500–4000 Hz ≥ 41 dB HL', () {
      expect(healthSuggestions(HealthReading(audiogram: _audiogram(left: 41, right: 60))).single.need,
          CareNeed.hearingImpaired);
      expect(healthSuggestions(HealthReading(audiogram: _audiogram(left: 40.9, right: 80))), isEmpty,
          reason: 'the better ear decides');
      expect(betterEarAverage(_audiogram(left: 50, right: 45)), 45);
      // 500/1000/2000/4000 averaged, not 250 / 8000.
      expect(
        betterEarAverage([
          const AudiogramPoint(hz: 250, left: 90, right: 90),
          const AudiogramPoint(hz: 500, left: 30, right: 30),
          const AudiogramPoint(hz: 1000, left: 40, right: 40),
          const AudiogramPoint(hz: 2000, left: 50, right: 50),
          const AudiogramPoint(hz: 4000, left: 60, right: 60),
          const AudiogramPoint(hz: 8000, left: 90, right: 90),
        ]),
        45,
      );
    });

    test('missing data never suggests anything', () {
      expect(healthSuggestions(const HealthReading()), isEmpty);
      expect(betterEarAverage(_audiogram(left: 70, right: 70, skip2k: true)), isNull, reason: 'a PTA frequency missing');
      expect(
        betterEarAverage([for (final hz in [500.0, 1000.0, 2000.0, 4000.0]) AudiogramPoint(hz: hz, left: 70)]),
        isNull,
        reason: 'one ear only: the better ear is unknown',
      );
      expect(healthSuggestions(const HealthReading(available: false, wheelchairUse: 'yes')).length, 1,
          reason: 'mapping is pure; the UI handles "unavailable"');
    });

    test('channel map parsing tolerates junk', () {
      final r = HealthReading.fromMap({
        'available': true, 'wheelchairUse': 'yes', 'walkingSteadiness': 0.3,
        'audiogram': [
          {'hz': 500, 'left': 45, 'right': null},
          {'hz': 'bad'},
          'junk',
        ],
      });
      expect(r.audiogram.single.left, 45);
      expect(r.audiogram.single.right, isNull);
      expect(HealthReading.fromMap(const {'available': false}).available, isFalse);
    });
  });

  group('suggestion card', () {
    Future<_FakeHealth> pumpForm(WidgetTester tester, HealthReading reading, {bool fail = false}) async {
      phoneView(tester);
      final storage = await signedInStorage();
      final health = _FakeHealth(reading, fail: fail);
      final hub = FakeHub()
        ..reply('GET /api/v1/me', 200, {
          'user_id': 'usr_ana', 'username': 'ana', 'display_name': 'Ana Popescu', 'role': 'resident',
          'units': [
            {'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'kind': 'residential'},
          ],
        })
        ..reply('GET /api/v1/me/care-profiles', 200, const []);
      await tester.pumpWidget(ProviderScope(
        overrides: [...hubOverrides(storage, hub), healthImportProvider.overrideWithValue(health)],
        child: Consumer(builder: (context, ref, _) => MaterialApp(
              locale: ref.watch(localeProvider),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const CareProfileFormScreen(),
            )),
      ));
      await settle(tester);
      return health;
    }

    testWidgets('only for "Pentru mine"; suggestions are off until added', (tester) async {
      final health = await pumpForm(
        tester,
        HealthReading(wheelchairUse: 'yes', walkingSteadiness: 0.3, audiogram: _audiogram(left: 55, right: 50)),
      );
      expect(find.text('Importă din Sănătate (Apple)'), findsNothing);
      await tester.tap(find.text('Pentru mine'));
      await settle(tester);
      await tester.tap(find.text('Importă din Sănătate (Apple)'));
      await settle(tester);
      expect(health.reads, 1);

      expect(find.text('Am găsit în Sănătate:'), findsOneWidget);
      expect(find.text('Scaun cu rotile — din profilul Sănătate'), findsOneWidget);
      expect(find.text('Mobilitate redusă — stabilitatea mersului 30 %'), findsOneWidget);
      expect(find.text('Nu aude alarma — audiogramă: 50 dB la urechea mai bună'), findsOneWidget);
      final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
      expect(switches.map((s) => s.value), [false, false, false], reason: 'never auto-applied');

      await tester.tap(find.text('Scaun cu rotile — din profilul Sănătate'));
      await tester.pump();
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value, isTrue);
      // The need is now selected in the picker (two "Scaun cu rotile" texts: card + picker).
      await tester.dragUntilVisible(find.text('De ce ajutor e nevoie?'), find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Scaun cu rotile'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('Scaun cu rotile')).flagsCollection.isChecked, CheckedState.isTrue);
      // Still no save without consent.
      await tester.dragUntilVisible(find.text('Salvează'), find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Salvează')).onPressed, isNull);
    });

    testWidgets('nothing found / read failure say so plainly', (tester) async {
      await pumpForm(tester, const HealthReading(wheelchairUse: 'notSet'));
      await tester.tap(find.text('Pentru mine'));
      await settle(tester);
      await tester.tap(find.text('Importă din Sănătate (Apple)'));
      await settle(tester);
      expect(find.text('Nu am găsit date relevante. Poți completa manual.'), findsOneWidget);
      expect(find.textContaining('iOS nu le spune aplicațiilor'), findsOneWidget);
    });

    testWidgets('read failure', (tester) async {
      await pumpForm(tester, const HealthReading(), fail: true);
      await tester.tap(find.text('Pentru mine'));
      await settle(tester);
      await tester.tap(find.text('Importă din Sănătate (Apple)'));
      await settle(tester);
      expect(find.text('Nu am putut citi date din Sănătate. Poți completa manual.'), findsOneWidget);
    });

    testWidgets('hidden where HealthKit is not supported (Android / web)', (tester) async {
      phoneView(tester);
      final storage = await signedInStorage();
      final hub = FakeHub()..reply('GET /api/v1/me/care-profiles', 200, const []);
      await tester.pumpWidget(ProviderScope(
        overrides: hubOverrides(storage, hub),
        child: Consumer(builder: (context, ref, _) => MaterialApp(
              locale: ref.watch(localeProvider),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const CareProfileFormScreen(),
            )),
      ));
      await settle(tester);
      await tester.tap(find.text('Pentru mine'));
      await settle(tester);
      expect(find.text('Importă din Sănătate (Apple)'), findsNothing); // test host is not iOS
    });
  });

  testWidgets('language sync: PATCH /me {"language"} after login and on each switch', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = FakeHub()
      ..reply('PATCH /api/v1/me', 422, {'detail': 'unknown field'}) // older hub: ignored
      ..reply('GET /api/v1/me/care-profiles', 200, const [])
      ..reply('GET /api/v1/buildings/bld/summary', 200, {'building_id': 'bld', 'status': 'ok', 'zones': []});
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, hub), child: const CanaryApp()));
    await settle(tester);
    expect(hub.calls('PATCH', '/api/v1/me').map((r) => r.data), [
      {'language': 'ro'},
    ]);

    final container = ProviderScope.containerOf(tester.element(find.byType(CanaryApp)));
    await container.read(localeProvider.notifier).setLanguage('en');
    await settle(tester);
    expect(hub.calls('PATCH', '/api/v1/me').map((r) => r.data), [
      {'language': 'ro'},
      {'language': 'en'},
    ]);
    expect(find.text('My rooms'), findsOneWidget, reason: 'a 422 changes nothing in the app');
  });
}
