import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:canary_resident/src/ui/settings_screen.dart';
import 'package:canary_resident/src/ui/widgets/classification_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

void main() {
  testWidgets('compact text handles model-only, unknown and closed assessments',
      (tester) async {
    phoneView(tester, textScale: 1.6);
    for (final entry in [
      ('normal', 'gas_leak', 'detection', true),
      ('normal', 'unknown', 'detection', false),
      ('unknown', null, 'detection', false),
      ('gas_leak', null, 'resolution', false),
    ]) {
      final incident = Incident.fromJson({
        'id': 'i',
        'building_id': 'bld',
        'state': entry.$3,
        'signature': {'label': entry.$1, 'shadow_label': entry.$2},
      });
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
            body: SizedBox(
                width: 240, child: ClassificationText(incident: incident))),
      ));
      await tester.pump();
      expect(find.textContaining('Rule assessment'),
          entry.$4 ? findsOneWidget : findsNothing);
      if (entry.$4) {
        expect(find.textContaining('Evaluation only · model: Gas leak'),
            findsOneWidget);
        expect(find.textContaining('EVACUATE'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }
  });

  for (final language in ['en', 'ro']) {
    for (final role in ['resident', 'hoa_manager']) {
      testWidgets('classification stays with $role alarm details in $language',
          (tester) async {
        phoneView(tester, textScale: 1.6);
        final storage = await signedInStorage(language: language, role: role);
        final incident = Incident.fromJson({
          'id': 'i',
          'building_id': 'bld',
          'state': 'detection',
          'hazard_type': 'particulate',
          'primary_zone_id': 'zone_bath',
          'signature': {
            'label': 'steam',
            'confidence': 0.8,
            'shadow_label': 'flaming_fire',
            'shadow_confidence': 0.9,
            'evidence': ['Humidity evidence'],
            'model_version': 'forest-v1',
          },
        });
        await tester.pumpWidget(ProviderScope(
          overrides: hubOverrides(storage, FakeHub(),
              incidents:
                  IncidentsState(incidents: [incident], connected: true)),
          child: const CanaryApp(),
        ));
        await settle(tester);
        expect(
            find.byKey(const ValueKey('classification-alerts')), findsNothing);
        final classification = find.textContaining('80%');
        await tester.scrollUntilVisible(classification, 120,
            scrollable: find.byType(Scrollable).first);
        expect(find.textContaining(language == 'en' ? 'Steam' : 'Abur'),
            findsWidgets);
        expect(
            find.textContaining(
                language == 'en' ? 'Evaluation only' : 'Doar pentru evaluare'),
            findsWidgets);
        expect(find.textContaining('90%'), findsWidgets);
        expect(find.textContaining('Humidity evidence'), findsNothing);
        expect(find.textContaining('forest-v1'), findsNothing);
        expect(tester.takeException(), isNull);

        final navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        navigator.push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
        await settle(tester);
        expect(find.textContaining('80%'), findsNothing);
        navigator.push(MaterialPageRoute<void>(
            builder: (_) => const AlarmScreen(incidentId: 'i')));
        await settle(tester);
        expect(find.textContaining('80%'), findsOneWidget);
        expect(find.textContaining('90%'), findsOneWidget);
        expect(
            find.byKey(const ValueKey('classification-alerts')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
