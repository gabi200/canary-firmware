import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/settings_screen.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/ui/widgets/classification_alerts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

void main() {
  for (final role in ['resident', 'hoa_manager']) {
    testWidgets(
        'app root retains model-only classification on $role secondary screens and hides after logout',
        (tester) async {
      phoneView(tester);
      final storage = await signedInStorage(language: 'en', role: role);
      final incident = Incident.fromJson({
        'id': 'i',
        'building_id': 'bld',
        'state': 'detection',
        'signature': {
          'label': 'normal',
          'shadow_label': 'gas_leak',
          'shadow_confidence': 0.9
        }
      });
      final otherBuilding = Incident.fromJson({
        'id': 'other',
        'building_id': 'elsewhere',
        'state': 'alarm',
        'signature': {'label': 'flaming_fire'}
      });
      await tester.pumpWidget(ProviderScope(
        overrides: hubOverrides(
            storage,
            FakeHub()
              ..reply('GET /api/v1/buildings/bld/zones', 200, [
                {'id': 'zone_bath', 'label': 'Baie'}
              ]),
            incidents: IncidentsState(incidents: [incident, otherBuilding])),
        child: const CanaryApp(),
      ));
      await settle(tester);
      expect(find.textContaining('Evaluation only'), findsOneWidget);
      expect(find.textContaining('Flaming fire'), findsNothing);
      expect(find.textContaining('EVACUATE'), findsNothing);
      final navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      navigator.push(
          MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      await settle(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.textContaining('Evaluation only'), findsOneWidget);
      navigator.push(MaterialPageRoute<void>(
          builder: (_) => const AlarmScreen(incidentId: 'i')));
      await settle(tester);
      expect(find.byType(AlarmScreen), findsOneWidget);
      expect(find.textContaining('Evaluation only'), findsOneWidget);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(CanaryApp)));
      await container.read(sessionProvider.notifier).logout();
      await settle(tester);
      expect(find.byKey(const ValueKey('classification-alerts')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in ['en', 'ro']) {
    testWidgets(
        'global classifications persist above routes in $language with bounded evidence',
        (tester) async {
      phoneView(tester, textScale: 1.6);
      final storage = await signedInStorage(language: language);
      final incident = Incident.fromJson({
        'id': 'i',
        'building_id': 'bld',
        'state': 'evacuation',
        'hazard_type': 'particulate',
        'primary_zone_id': 'zone_bath',
        'signature': {
          'label': 'steam',
          'confidence': 0.8,
          'shadow_label': 'flaming_fire',
          'shadow_confidence': 0.9,
          'model_version': 'forest-v1',
          'ts': '2026-11-04T12:00:00Z',
          'evidence': List.generate(20, (i) => 'Humidity evidence $i')
        },
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ProviderScope(
        overrides: hubOverrides(
            storage,
            FakeHub()
              ..reply('GET /api/v1/buildings/bld/zones', 200, [
                {'id': 'zone_bath', 'label': 'Baie'}
              ]),
            incidents: IncidentsState(incidents: [incident])),
        child: MaterialApp(
            navigatorKey: navigator,
            locale: Locale(language),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => ClassificationAlerts(child: child!),
            home: const Scaffold(body: Text('Home route'))),
      ));
      await settle(tester);
      expect(
          find.textContaining(
              language == 'en' ? 'Rule assessment' : 'Evaluare prin reguli'),
          findsOneWidget);
      expect(
          find.textContaining(
              language == 'en' ? 'Evaluation only' : 'Doar pentru evaluare'),
          findsOneWidget);
      expect(find.textContaining('Baie'), findsOneWidget);
      expect(tester.getBottomRight(find.textContaining('80%')).dy,
          lessThanOrEqualTo(228));
      expect(find.textContaining('80%'), findsOneWidget);
      expect(find.textContaining('90%'), findsOneWidget);
      expect(find.textContaining('forest-v1'), findsOneWidget);
      expect(find.textContaining(language == 'en' ? 'EVACUATE' : 'EVACUA'),
          findsWidgets);
      expect(
          find.textContaining(lookupAppLocalizations(Locale(language))
              .clockTime(DateTime.utc(2026, 11, 4, 12))),
          findsOneWidget);
      navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Settings route'))));
      await settle(tester);
      expect(find.text('Settings route'), findsOneWidget);
      expect(find.textContaining('80%'), findsOneWidget);
      await tester
          .ensureVisible(find.text(language == 'en' ? 'Evidence' : 'Dovezi'));
      await tester.tap(find.text(language == 'en' ? 'Evidence' : 'Dovezi'));
      await settle(tester);
      expect(find.text('Humidity evidence 0'), findsOneWidget);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('classification-alerts')))
              .height,
          lessThanOrEqualTo(228));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('normal unknown and closed incidents are hidden', (tester) async {
    final storage = await signedInStorage();
    final incidents = [
      for (final entry in [
        ('normal', 'detection'),
        ('unknown', 'detection'),
        ('gas_leak', 'resolution')
      ])
        Incident.fromJson({
          'id': entry.$1,
          'building_id': 'bld',
          'state': entry.$2,
          'signature': {'label': entry.$1}
        }),
    ];
    await tester.pumpWidget(ProviderScope(
      overrides: hubOverrides(storage, FakeHub(),
          incidents: IncidentsState(incidents: incidents)),
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ClassificationAlerts(child: child!),
          home: const Scaffold(body: Text('home'))),
    ));
    await settle(tester);
    expect(find.byKey(const ValueKey('classification-alerts')), findsNothing);
  });
}
