// Household invites: code extraction, deep-link routes, accept flow with the
// optional take-over consent, error mapping, the "My apartment" screen and the
// share sheet — Romanian, 360 dp, 1.3x text.
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/household.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/household_screen.dart';
import 'package:canary_resident/src/ui/invite_accept_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

Map<String, Object?> _preview({bool care = true}) => {
      'building_name': 'Bloc Canary', 'unit_label': 'Ap. 12', 'floor_label': 'Etaj 3', 'inviter_name': 'Ana Popescu',
      'has_care_profile': care, 'care_profile_name': care ? 'Bunica Maria' : null,
      'expires_ts': DateTime.now().toUtc().add(const Duration(hours: 72)).toIso8601String(),
    };

FakeHub _hub() => FakeHub()
  ..reply('GET /api/v1/me/care-profiles', 200, const [])
  ..reply('GET /api/v1/buildings/bld/summary', 200, {'building_id': 'bld', 'status': 'ok', 'zones': []})
  ..reply('GET /api/v1/household/invites/ABCD2345', 200, _preview())
  ..reply('POST /api/v1/household/invites/ABCD2345/accept', 200,
      {'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'building_id': 'bld', 'care_profile_id': 'cp1'});

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

FilledButton _button(WidgetTester tester, String text) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, text));

void main() {
  group('codes and routes', () {
    test('extract the code from a code or any link form', () {
      expect(extractInviteCode('ABCD2345'), 'ABCD2345');
      expect(extractInviteCode('  abcd-23_45 \n'), 'abcd-23_45');
      expect(extractInviteCode('https://hub.local/join/ABCD2345'), 'ABCD2345');
      expect(extractInviteCode('http://192.168.1.20/join/ABCD2345/?utm=x'), 'ABCD2345');
      expect(extractInviteCode('canary://join/ABCD2345'), 'ABCD2345');
      expect(extractInviteCode('http://hub:8088/#/join/ABCD2345'), 'ABCD2345');
      expect(extractInviteCode('Intră în apartament: https://hub/join/ABCD2345'), 'ABCD2345');
      expect(extractInviteCode(''), isNull);
      expect(extractInviteCode('nu e un cod!'), isNull);
      expect(extractInviteCode('abc'), isNull);
    });

    test('deep-link routes', () {
      expect(inviteCodeFromRoute('/join/ABCD2345'), 'ABCD2345'); // https / web
      expect(inviteCodeFromRoute('/ABCD2345'), 'ABCD2345'); // canary://join/ABCD2345
      expect(inviteCodeFromRoute('/join/ABCD2345?x=1'), 'ABCD2345');
      expect(inviteCodeFromRoute('/'), isNull);
      expect(inviteCodeFromRoute('/join'), isNull);
      expect(inviteCodeFromRoute('/a/b/c'), isNull);
      expect(inviteCodeFromRoute(null), isNull);
    });

    test('errors in plain Romanian', () async {
      final ro = lookupAppLocalizations(const Locale('ro'));
      Future<String> err(int status) async {
        final hub = FakeHub()..reply('POST /api/v1/household/invites/X1234/accept', status, {'detail': 'x'});
        try {
          await fakeApi(hub).acceptInvite('X1234', takeOverCareProfile: false, consent: false);
        } catch (e) {
          return ro.inviteError(e);
        }
        return 'ok';
      }

      expect(await err(403), 'Doar locatarii pot intra într-un apartament.');
      expect(await err(404), startsWith('Invitația nu mai e valabilă'));
      expect(await err(409), startsWith('Nu poți accepta propria invitație'));
      expect(await err(422), 'Bifează acordul ca să preiei profilul.');
      expect(await err(429), startsWith('Prea multe încercări'));
    });
  });

  testWidgets('accept: preview, optional take-over gated on a separate consent', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub();
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const InviteAcceptScreen(code: 'ABCD2345')));
    await _open(tester);

    expect(find.text('Ana Popescu te invită în'), findsOneWidget);
    expect(find.text('Bloc Canary'), findsOneWidget);
    expect(find.text('Etaj 3'), findsOneWidget);
    expect(find.textContaining('a creat un profil de urgență pentru tine (Bunica Maria)'), findsOneWidget);
    // Taking over is optional: Accept works without it.
    await tester.dragUntilVisible(find.text('Acceptă'), find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(_button(tester, 'Acceptă').onPressed, isNotNull);

    await tester.dragUntilVisible(find.text('Da, preiau profilul'), find.byType(ListView), const Offset(0, 150));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Da, preiau profilul'));
    await tester.pump();
    final consent = find.textContaining('Sunt de acord ca aceste informații despre sănătate');
    expect(consent, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.ancestor(of: consent, matching: find.byType(CheckboxListTile))).value,
        isFalse);
    await tester.dragUntilVisible(find.text('Acceptă'), find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(_button(tester, 'Acceptă').onPressed, isNull, reason: 'take-over without consent');

    await tester.dragUntilVisible(consent, find.byType(ListView), const Offset(0, 150));
    await tester.pumpAndSettle();
    await tester.tap(consent);
    await tester.pump();
    await tester.dragUntilVisible(find.text('Acceptă'), find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Acceptă'));
    await settle(tester);
    expect(hub.calls('POST', '/api/v1/household/invites/ABCD2345/accept').single.data,
        {'take_over_care_profile': true, 'consent': true});
    expect(find.text('Ai intrat în Ap. 12'), findsOneWidget);
    expect(find.text('open'), findsOneWidget, reason: 'back on the first screen');
  });

  testWidgets('accept: invalid code and staff accounts', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage(role: 'hoa_manager');
    final hub = _hub()
      ..reply('GET /api/v1/household/invites/ABCD2345', 200, _preview(care: false))
      ..reply('POST /api/v1/household/invites/ABCD2345/accept', 403, {'detail': 'staff'});
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const InviteAcceptScreen(code: 'ABCD2345')));
    await _open(tester);
    expect(find.textContaining('a creat un profil de urgență'), findsNothing);
    await tester.tap(find.text('Acceptă'));
    await settle(tester);
    expect(find.text('Doar locatarii pot intra într-un apartament.'), findsOneWidget);
  });

  testWidgets('accept: an invalid / expired / used code', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub404 = _hub()..reply('GET /api/v1/household/invites/ZZZZ9999', 404, {'detail': 'Not found'});
    await tester.pumpWidget(_app(hubOverrides(storage, hub404), const InviteAcceptScreen(code: 'ZZZZ9999')));
    await _open(tester);
    expect(find.textContaining('Invitația nu mai e valabilă'), findsOneWidget);
  });

  testWidgets('deep link: canary://join/<code> opens the accept screen', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, _hub()), child: const CanaryApp()));
    await settle(tester);
    await tester.binding.handlePushRoute('/ABCD2345');
    await settle(tester);
    expect(find.text('Invitație'), findsOneWidget);
    expect(find.text('Ana Popescu te invită în'), findsOneWidget);
  });

  testWidgets('deep link while signed out: sign in first, then the invite', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await storage.clearSession();
    final hub = _hub()
      ..reply('POST /api/v1/auth/token', 200, {'access_token': 't', 'token_type': 'bearer', 'role': 'resident', 'user_id': 'usr_ioana'});
    await tester.pumpWidget(ProviderScope(overrides: hubOverrides(storage, hub), child: const CanaryApp()));
    await settle(tester);
    await tester.binding.handlePushRoute('/join/ABCD2345');
    await settle(tester);
    expect(find.text('Intră în cont ca să accepți invitația.'), findsOneWidget);
    await tester.tap(find.text('Conectează-mi apartamentul').last);
    await settle(tester);
    expect(find.text('Ana Popescu te invită în'), findsOneWidget);
  });

  testWidgets('My apartment: members, pending invites, invite sheet, leave confirm', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    final hub = _hub()
      ..reply('GET /api/v1/me/household', 200, [
        {
          'unit_id': 'unit_0312', 'unit_label': 'Ap. 12',
          'members': [
            {'user_id': 'usr_ana', 'display_name': 'Ana Popescu', 'is_me': true, 'since': '2026-09-01T10:00:00Z'},
            {'user_id': 'usr_ioana', 'display_name': 'Ioana Popescu', 'is_me': false},
          ],
        },
      ])
      ..reply('GET /api/v1/me/household/invites', 200, [
        {'id': 'inv1', 'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'care_profile_id': 'cp1',
         'care_profile_name': 'Bunica Maria', 'expires_ts': '2026-10-12T21:40:00Z'},
      ])
      ..reply('POST /api/v1/me/household/invites', 201, {
        'id': 'inv2', 'code': 'QWER5678', 'url': 'http://hub.local/join/QWER5678', 'app_url': 'canary://join/QWER5678',
        'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'care_profile_id': null,
        'expires_ts': DateTime.now().toUtc().add(const Duration(hours: 72)).toIso8601String(),
      })
      ..reply('DELETE /api/v1/me/household/invites/inv1', 204);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.pumpWidget(_app(hubOverrides(storage, hub), const HouseholdScreen()));
    await _open(tester);

    expect(find.text('Apartamentul meu'), findsOneWidget);
    expect(find.text('Ioana Popescu'), findsOneWidget);
    expect(find.text('Eu'), findsOneWidget);
    expect(find.text('pentru Bunica Maria'), findsOneWidget);
    expect(find.textContaining('Expiră: '), findsOneWidget);

    await tester.tap(find.byTooltip('Anulează invitația'));
    await settle(tester);
    expect(hub.calls('DELETE', '/api/v1/me/household/invites/inv1'), hasLength(1));

    await tester.dragUntilVisible(find.text('Invită pe cineva cu cont'), find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invită pe cineva cu cont'));
    await settle(tester);
    expect(hub.calls('POST', '/api/v1/me/household/invites').single.data,
        {'unit_id': 'unit_0312', 'care_profile_id': null});
    expect(find.text('http://hub.local/join/QWER5678'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Expiră în (71|72) de ore, o singură folosire\.$')), findsOneWidget);
    expect(find.text('Trimite prin SMS'), findsOneWidget);
    expect(find.text('Trimite pe email'), findsOneWidget);
    await tester.tap(find.text('Copiază linkul'));
    await settle(tester);
    expect(copied, 'http://hub.local/join/QWER5678');
    expect(find.text('Link copiat'), findsOneWidget);

    Navigator.of(tester.element(find.text('Copiază linkul'))).pop();
    await settle(tester);
    await tester.dragUntilVisible(find.text('Părăsește apartamentul'), find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Părăsește apartamentul'));
    await settle(tester);
    expect(find.text('Părăsești Ap. 12?'), findsOneWidget);
    expect(find.textContaining('Profilurile de urgență pe care le-ai creat pentru el se șterg.'), findsOneWidget);
    await tester.tap(find.text('Anulează'));
    await settle(tester);
    expect(hub.calls('DELETE', '/api/v1/me/household/unit_0312'), isEmpty);
  });

  testWidgets('invite code entry extracts a pasted link', (tester) async {
    phoneView(tester);
    final storage = await signedInStorage();
    await tester.pumpWidget(_app(hubOverrides(storage, _hub()), const InviteCodeEntryScreen()));
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'nu e cod!');
    await tester.pump();
    await tester.tap(find.text('Continuă'));
    await settle(tester);
    expect(find.text('Nu pare un cod de invitație.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Intră: http://hub.local/join/ABCD2345');
    await tester.pump();
    await tester.tap(find.text('Continuă'));
    await settle(tester);
    expect(find.text('Ana Popescu te invită în'), findsOneWidget);
  });
}
