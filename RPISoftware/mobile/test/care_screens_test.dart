// Emergency profiles + account screens, in Romanian at 360 dp with 1.3x text:
// consent gating, note limit, delete confirm, home hint, household check-in on
// the alarm screen, account edit with 422 mapping. No overflow anywhere.
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/account_screen.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:canary_resident/src/ui/widgets/household_checkin.dart';
import 'package:canary_resident/src/ui/care_profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

Map<String, Object?> _grandma({String id = 'cp1'}) => {
      'id': id, 'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'display_name': 'Bunica Maria',
      'is_self': false, 'needs': ['wheelchair', 'hearing_impaired'], 'note': null,
      'consent_ts': '2026-10-09T20:00:00Z', 'updated_ts': '2026-10-09T20:00:00Z',
    };

Map<String, Object?> _me({String name = 'Ana Popescu', String? phone = '+40722123456'}) => {
      'user_id': 'usr_ana', 'username': 'ana', 'display_name': name, 'role': 'resident',
      'phone': phone, 'email': null,
      'units': [
        {'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'building_id': 'bld', 'floor_label': 'Etaj 3', 'kind': 'residential'},
      ],
    };

FakeHub _hub({List<Object?> profiles = const []}) => FakeHub()
  ..reply('GET /api/v1/me', 200, _me())
  ..reply('GET /api/v1/me/care-profiles', 200, profiles)
  ..reply('GET /api/v1/buildings/bld/incidents', 200, const [])
  ..reply('GET /api/v1/buildings/bld/summary', 200,
      {'building_id': 'bld', 'status': 'ok', 'headline': 'Totul e în regulă', 'zones': []});

/// A localized app whose home pushes [screen] (so the form can pop on save).
Widget _app(List<Override> overrides, Widget screen) => ProviderScope(
      overrides: overrides,
      child: Consumer(builder: (context, ref, _) => MaterialApp(
            locale: ref.watch(localeProvider),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
                      child: const Text('open'),
                    ),
                  ),
                )),
          )),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await settle(tester);
}

/// Drags the top route's list until [f] is built and on screen.
Future<void> _scrollTo(WidgetTester tester, Finder f, {bool up = false}) async {
  await tester.dragUntilVisible(f, find.byType(ListView).last, Offset(0, up ? 150 : -150));
  await tester.ensureVisible(f);
  // Let the scroll settle: a list ignores taps while it is still moving.
  await tester.pumpAndSettle();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Salvează'));

/// Scrolls to the save button and says whether it is enabled.
Future<bool> _canSave(WidgetTester tester) async {
  await _scrollTo(tester, find.text('Salvează'));
  return _saveButton(tester).onPressed != null;
}

void main() {
  testWidgets('form: save needs explicit consent and a need or a note; note capped at 280', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub()..reply('POST /api/v1/me/care-profiles', 201, _grandma(id: 'cp9'));
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const CareProfileFormScreen()));
    await _open(tester);

    expect(find.text('Profil nou'), findsOneWidget);
    expect(find.text('Altă persoană din casă'), findsOneWidget);
    expect(await _canSave(tester), isFalse);

    await _scrollTo(tester, find.widgetWithText(TextField, 'Nume'), up: true);
    await tester.enterText(find.widgetWithText(TextField, 'Nume'), 'Bunica Maria');
    await _scrollTo(tester, find.text('Scaun cu rotile'));
    await tester.tap(find.text('Scaun cu rotile'));
    await tester.pump();
    expect(await _canSave(tester), isFalse, reason: 'consent not given');

    final consent = find.byType(CheckboxListTile);
    await _scrollTo(tester, consent, up: true);
    expect(tester.widget<CheckboxListTile>(consent).value, isFalse, reason: 'never pre-ticked');
    await tester.tap(consent);
    await tester.pump();
    expect(await _canSave(tester), isTrue);

    // Without any need and without a note: disabled again; a note alone is enough.
    await _scrollTo(tester, find.text('Scaun cu rotile'), up: true);
    await tester.tap(find.text('Scaun cu rotile'));
    await tester.pump();
    expect(await _canSave(tester), isFalse);
    final note = find.widgetWithText(TextField, 'Notă (opțional)');
    await _scrollTo(tester, note, up: true);
    await tester.enterText(note, 'x' * 300);
    await tester.pump();
    expect(tester.widget<TextField>(note).controller!.text.length, 280);
    expect(find.text('280/280'), findsOneWidget);
    expect(await _canSave(tester), isTrue);

    await _scrollTo(tester, note, up: true);
    await tester.enterText(note, 'Folosește cadru');
    await _scrollTo(tester, find.text('Salvează'));
    await tester.tap(find.text('Salvează'));
    await settle(tester);
    final body = hub.calls('POST', '/api/v1/me/care-profiles').single.data as Map;
    expect(body, {
      'unit_id': 'unit_0312', 'display_name': 'Bunica Maria', 'is_self': false,
      'needs': <String>[], 'note': 'Folosește cadru', 'consent': true,
    });
    expect(find.text('Profil salvat'), findsOneWidget);
    expect(find.text('Profil nou'), findsNothing); // popped
  });

  testWidgets('form: "Pentru mine" prefills the name; 503 shows "not active"', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub()..reply('POST /api/v1/me/care-profiles', 503, {'detail': 'no key'});
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const CareProfileFormScreen()));
    await _open(tester);

    await tester.tap(find.text('Pentru mine'));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Ana Popescu'), findsOneWidget);
    await tester.tap(find.text('Nu aude alarma'));
    await _scrollTo(tester, find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await _scrollTo(tester, find.text('Salvează'));
    await tester.tap(find.text('Salvează'));
    await settle(tester);
    expect((hub.calls('POST', '/api/v1/me/care-profiles').single.data as Map)['is_self'], isTrue);
    expect(find.text('Funcția nu e activă pe acest hub.'), findsOneWidget);
  });

  testWidgets('list + delete with confirmation', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub(profiles: [_grandma()])..reply('DELETE /api/v1/me/care-profiles/cp1', 204);
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const CareProfilesScreen()));
    await _open(tester);

    expect(find.text('Profil de urgență'), findsOneWidget);
    expect(find.text('Bunica Maria'), findsOneWidget);
    expect(find.text('Scaun cu rotile'), findsOneWidget);
    await tester.tap(find.text('Bunica Maria'));
    await settle(tester);
    expect(find.text('Modifică profilul'), findsOneWidget);

    await _scrollTo(tester, find.text('Șterge profilul'));
    await tester.tap(find.text('Șterge profilul'));
    await settle(tester);
    expect(find.text('Ștergi profilul?'), findsOneWidget);
    expect(find.text('Informațiile se șterg definitiv.'), findsOneWidget);
    await tester.tap(find.text('Anulează'));
    await settle(tester);
    expect(hub.calls('DELETE', '/api/v1/me/care-profiles/cp1'), isEmpty);

    await tester.tap(find.text('Șterge profilul'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Șterge'));
    await settle(tester);
    expect(hub.calls('DELETE', '/api/v1/me/care-profiles/cp1'), hasLength(1));
    expect(find.text('Profil șters'), findsOneWidget);
    // Back on the list: empty state.
    expect(find.text('Bunica Maria'), findsNothing);
    expect(find.textContaining('Dacă cineva din casă nu poate ieși singur'), findsOneWidget);
  });

  testWidgets('home hint: shown with no profiles, dismissal persists', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);
    expect(find.text('Cineva din casă are nevoie de ajutor să iasă?'), findsOneWidget);
    await tester.tap(find.byTooltip('Închideți'));
    await settle(tester);
    expect(find.text('Cineva din casă are nevoie de ajutor să iasă?'), findsNothing);
    expect(storage.careHintDismissed, isTrue);
  });

  testWidgets('home hint: hidden when a profile exists', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(
        ProviderScope(overrides: hubOverrides(storage, _hub(profiles: [_grandma()])), child: const CanaryApp()));
    await settle(tester);
    expect(find.text('Cineva din casă are nevoie de ajutor să iasă?'), findsNothing);
  });

  testWidgets('alarm screen: household rows post care check-ins; failures offer retry', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub(profiles: [
      {..._grandma(id: 'cp0'), 'is_self': true, 'display_name': 'Ana Popescu'},
      _grandma(),
    ])
      ..reply('POST /api/v1/incidents/inc/care-checkin', 503, {'detail': 'offline'})
      ..reply('GET /api/v1/buildings/bld/evacuation', 200, {'routes': [], 'assembly_points': []});
    const incident = Incident(
        id: 'inc', buildingId: 'bld', hazardType: 'combustible_gas', severity: 'critical', state: 'evacuation');
    await tester.pumpWidget(_app(
      hubOverrides(storage, hub, incidents: const IncidentsState(incidents: [incident], connected: true)),
      const AlarmScreen(incidentId: 'inc'),
    ));
    await _open(tester);

    expect(find.text('EVACUAȚI ACUM'), findsOneWidget);
    // Own check-in buttons stay first.
    expect(find.text('Am ieșit, sunt în siguranță'), findsOneWidget);
    final title = find.text('Cine mai e în casă?');
    final body = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(title, 200, scrollable: body);
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(title);
    expect(find.text('Bunica Maria'), findsOneWidget);
    expect(find.text('Ana Popescu'), findsNothing); // "Eu" isn't listed
    expect(find.text('Scaun cu rotile · Nu aude alarma'), findsOneWidget);

    // The household row's "Afară", not the "Unde ești acum?" answer.
    final out = find.descendant(of: find.byType(HouseholdCheckIn), matching: find.text('Afară'));
    await tester.ensureVisible(out);
    await tester.pump();
    await tester.tap(out);
    await settle(tester);
    expect(hub.calls('POST', '/api/v1/incidents/inc/care-checkin').single.data,
        {'care_profile_id': 'cp1', 'status': 'safe_outside'});
    expect(find.text('Afară · Netrimis — fără conexiune.'), findsOneWidget);

    hub.reply('POST /api/v1/incidents/inc/care-checkin', 200, {'ok': true});
    await tester.tap(find.text('Reîncearcă'));
    await settle(tester);
    expect(find.text('Trimis: Afară'), findsOneWidget);

    // The resident checks in: household rows move to the bottom bar, state kept.
    hub.reply('POST /api/v1/incidents/inc/checkin', 200, {'ok': true});
    await tester.tap(find.text('Am ieșit, sunt în siguranță'));
    await settle(tester);
    expect(find.text('Trimis: Afară'), findsOneWidget);
    expect(find.text('Cine mai e în casă?'), findsOneWidget);
  });

  testWidgets('account: only changed fields are sent; 422 shown under the field', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub()
      ..on('PATCH /api/v1/me', (r) => (r.data as Map)['phone'] == '12'
          ? (422, {'detail': [{'loc': ['body', 'phone'], 'msg': 'Număr de telefon invalid'}]})
          : (200, _me(phone: '+40722999888')));
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const AccountScreen()));
    await _open(tester);

    expect(find.text('Contul meu'), findsOneWidget);
    expect(find.text('Pe acest număr te sună dispecerul în caz de urgență'), findsOneWidget);
    await _scrollTo(tester, find.text('Ap. 12 · Etaj 3'));
    expect(find.text('Locatar'), findsOneWidget);
    expect(await _canSave(tester), isFalse, reason: 'nothing changed');
    await _scrollTo(tester, find.widgetWithText(TextField, 'Telefon'), up: true);
    expect(find.text('+40722123456'), findsOneWidget);

    final phone = find.widgetWithText(TextField, 'Telefon');
    await tester.enterText(phone, '12ab');
    await tester.pump();
    expect(find.text('Scrie un număr de telefon valid, de ex. 0722 123 456'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(phone, '12');
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull, reason: 'too short locally');
    await tester.enterText(phone, '0722 999 888');
    await tester.pump();
    await _scrollTo(tester, find.text('Salvează'));
    await tester.tap(find.text('Salvează'));
    await settle(tester);
    expect(hub.calls('PATCH', '/api/v1/me').single.data, {'phone': '0722 999 888'});
    expect(find.text('Contul a fost salvat'), findsOneWidget);
    await _scrollTo(tester, find.widgetWithText(TextField, 'Telefon'), up: true);
    expect(find.text('+40722999888'), findsOneWidget); // normalized by the hub
  });

  testWidgets('account: hub 422 message appears under the phone field', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub()
      ..reply('PATCH /api/v1/me', 422, {'detail': 'Numărul de telefon nu este valid.'});
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const AccountScreen()));
    await _open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Telefon'), '+40 999 999 999 99');
    await tester.pump();
    await _scrollTo(tester, find.text('Salvează'));
    await tester.tap(find.text('Salvează'));
    await settle(tester);
    await _scrollTo(tester, find.widgetWithText(TextField, 'Telefon'), up: true);
    expect(find.text('Numărul de telefon nu este valid.'), findsOneWidget);
  });
}
