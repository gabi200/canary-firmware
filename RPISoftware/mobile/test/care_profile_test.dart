import 'dart:convert';

import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/models/care_profile.dart';
import 'package:canary_resident/src/models/check_in.dart';
import 'package:canary_resident/src/models/me.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

final _ro = lookupAppLocalizations(const Locale('ro'));

Map<String, Object?> _profileJson({String id = 'cp1', bool self = false, List<String> needs = const ['wheelchair']}) => {
      'id': id, 'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'display_name': 'Bunica Maria',
      'is_self': self, 'needs': needs, 'note': 'Doarme în camera din spate',
      'consent_ts': '2026-10-09T20:00:00Z', 'updated_ts': '2026-10-09T20:00:00Z',
    };

void main() {
  group('care profile model', () {
    test('parses, keeps known needs in a stable order, drops unknown codes', () {
      final p = CareProfile.fromJson(_profileJson(needs: ['pet', 'jetpack', 'wheelchair']));
      expect(p.needs, [CareNeed.wheelchair, CareNeed.pet]);
      expect(p.unitLabel, 'Ap. 12');
      expect(p.isSelf, isFalse);
    });

    test('draft payload: codes, trimmed name, blank note → null, consent', () {
      final body = const CareProfileDraft(
        unitId: 'unit_0312', displayName: '  Bunica  ', isSelf: false,
        needs: {CareNeed.youngChild, CareNeed.reducedMobility}, note: '   ', consent: true,
      ).toJson();
      expect(body, {
        'unit_id': 'unit_0312', 'display_name': 'Bunica', 'is_self': false,
        'needs': ['reduced_mobility', 'young_child'], 'note': null, 'consent': true,
      });
    });

    test('save is gated on explicit consent and on a need or a note', () {
      bool ready({String name = 'Maria', Set<CareNeed> needs = const {CareNeed.bedridden}, String note = '',
              bool consent = true, String? unit = 'unit_0312'}) =>
          careDraftReady(name: name, needs: needs, note: note, consent: consent, unitId: unit);
      expect(ready(), isTrue);
      expect(ready(consent: false), isFalse);
      expect(ready(needs: const {}), isFalse);
      expect(ready(needs: const {}, note: 'Folosește cadru'), isTrue);
      expect(ready(needs: const {}, note: '   '), isFalse);
      expect(ready(name: ' '), isFalse);
      expect(ready(unit: null), isFalse);
      expect(ready(note: 'x' * careNoteMaxLength), isTrue);
      expect(ready(note: 'x' * (careNoteMaxLength + 1)), isFalse);
    });

    test('own units from visible zones skip common areas', () {
      expect(
        ownUnitIds(
          visibleZoneIds: ['zone_kitchen', 'zone_bedroom', 'zone_boiler', 'zone_unknown'],
          zoneUnits: {'zone_kitchen': 'unit_0312', 'zone_bedroom': 'unit_0312', 'zone_boiler': 'common'},
        ),
        ['unit_0312'],
      );
    });

    test('/me: residential units only', () {
      final me = MeProfile.fromJson({
        'user_id': 'usr_ana', 'username': 'ana', 'display_name': 'Ana Popescu', 'role': 'resident',
        'phone': '+40722123456', 'email': null,
        'units': [
          {'unit_id': 'unit_0312', 'unit_label': 'Ap. 12', 'building_id': 'bld_007', 'floor_label': 'Etaj 3', 'kind': 'residential'},
          {'unit_id': 'common', 'unit_label': 'Comun', 'kind': 'common'},
        ],
      });
      expect(me.residentialUnits, [const UnitRef('unit_0312', 'Ap. 12')]);
      expect(me.residentialUnits.single.label, 'Ap. 12');
      expect(me.email, isNull);
    });
  });

  group('care API client', () {
    test('list / create / update / delete / care check-in hit the contract', () async {
      final hub = FakeHub()
        ..reply('GET /api/v1/me/care-profiles', 200, [_profileJson(), _profileJson(id: 'cp0', self: true)])
        ..reply('POST /api/v1/me/care-profiles', 201, _profileJson(id: 'cp2'))
        ..reply('PUT /api/v1/me/care-profiles/cp2', 200, _profileJson(id: 'cp2', needs: ['pet']))
        ..reply('DELETE /api/v1/me/care-profiles/cp2', 204)
        ..reply('POST /api/v1/incidents/inc1/care-checkin', 200, {'ok': true});
      final api = fakeApi(hub);
      const draft = CareProfileDraft(
          unitId: 'unit_0312', displayName: 'Maria', isSelf: false, needs: {CareNeed.pet}, note: '', consent: true);

      expect((await api.careProfiles()).map((p) => p.id), ['cp1', 'cp0']);
      expect((await api.createCareProfile(draft)).id, 'cp2');
      expect((await api.updateCareProfile('cp2', draft)).needs, [CareNeed.pet]);
      await api.deleteCareProfile('cp2');
      await api.careCheckIn('inc1', 'cp1', CheckInStatus.needsHelp);

      final post = hub.calls('POST', '/api/v1/me/care-profiles').single;
      expect(post.data, draft.toJson());
      expect((post.data as Map)['consent'], isTrue);
      expect(hub.calls('PUT', '/api/v1/me/care-profiles/cp2').single.data, draft.toJson());
      expect(hub.calls('DELETE', '/api/v1/me/care-profiles/cp2'), hasLength(1));
      expect(hub.calls('POST', '/api/v1/incidents/inc1/care-checkin').single.data,
          {'care_profile_id': 'cp1', 'status': 'needs_help'});
    });

    test('errors map to plain Romanian', () async {
      final hub = FakeHub();
      final api = fakeApi(hub);
      const draft = CareProfileDraft(
          unitId: 'u', displayName: 'M', isSelf: true, needs: {CareNeed.pet}, note: '', consent: true);
      Future<String> errorFor(int status) async {
        hub.reply('POST /api/v1/me/care-profiles', status, {'detail': 'x'});
        try {
          await api.createCareProfile(draft);
        } catch (e) {
          return _ro.careError(e);
        }
        return 'no error';
      }

      expect(await errorFor(503), 'Funcția nu e activă pe acest hub.');
      expect(await errorFor(409), 'Ai deja un profil pentru tine.');
      expect(await errorFor(404), 'Acest apartament nu este asociat contului tău.');
      expect(await errorFor(422), startsWith('Verifică datele'));
    });

    test('a hub without /me yet answers null, not an error', () async {
      final api = fakeApi(FakeHub());
      expect(await api.me(), isNull);
    });
  });

  group('account edit', () {
    const original = MeProfile(
        userId: 'u', username: 'ana', role: 'resident', displayName: 'Ana', phone: '+40722123456');

    test('PATCH carries only the changed fields; "" clears', () {
      expect(const AccountEdit(original: original, displayName: 'Ana', phone: '+40722123456', email: '').changes, isEmpty);
      expect(const AccountEdit(original: original, displayName: 'Ana Popescu ', phone: '+40722123456', email: '').changes,
          {'display_name': 'Ana Popescu'});
      expect(const AccountEdit(original: original, displayName: 'Ana', phone: '', email: 'ana@example.ro').changes,
          {'phone': '', 'email': 'ana@example.ro'});
    });

    test('local validation', () {
      expect(validateDisplayName('  '), AccountFieldError.nameRequired);
      expect(validatePhone(''), isNull);
      expect(validatePhone('0722 123 456'), isNull);
      expect(validatePhone('+40 (722) 123-456'), isNull);
      expect(validatePhone('12ab'), AccountFieldError.phoneInvalid);
      expect(validatePhone('123'), AccountFieldError.phoneInvalid);
      expect(validateEmail(''), isNull);
      expect(validateEmail('ana@example.ro'), isNull);
      expect(validateEmail('ana@'), AccountFieldError.emailInvalid);
    });

    test('422 details map to fields', () async {
      expect(parseErrorDetail('Număr de telefon invalid').$1, 'Număr de telefon invalid');
      final list = parseErrorDetail([
        {'loc': ['body', 'phone'], 'msg': 'Invalid phone number', 'type': 'value_error'},
        {'loc': ['body', 'email'], 'msg': 'Invalid email', 'type': 'value_error'},
      ]);
      expect(list.$2, {'phone': 'Invalid phone number', 'email': 'Invalid email'});
      expect(parseErrorDetail({'field': 'email', 'message': 'Adresă invalidă'}).$2, {'email': 'Adresă invalidă'});

      final hub = FakeHub()
        ..reply('PATCH /api/v1/me', 422, {
          'detail': [
            {'loc': ['body', 'phone'], 'msg': 'Număr de telefon invalid'},
          ],
        });
      try {
        await fakeApi(hub).updateMe({'phone': '12'});
        fail('expected 422');
      } on ApiException catch (e) {
        expect(e.statusCode, 422);
        expect(e.fieldErrors, {'phone': 'Număr de telefon invalid'});
      }
      expect(jsonEncode(hub.requests.single.data), '{"phone":"12"}');
    });
  });
}
