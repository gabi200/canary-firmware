// The phone follows the hub's demo / real mode: the mode's building becomes the
// session's building (saved, and the per-building providers follow), a failed
// poll keeps the current building, nothing polls while signed out, and "my
// home" only ever means the units of the session's building.
import 'dart:convert';

import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/models/me.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/account_providers.dart';
import 'package:canary_resident/src/state/care_providers.dart';
import 'package:canary_resident/src/state/household_providers.dart';
import 'package:canary_resident/src/state/mode_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_hub.dart';

const _modePath = 'GET /api/v1/mode';

Future<Storage> _storage({String? building}) async {
  SharedPreferences.setMockInitialValues({
    if (building != null)
      'session': jsonEncode(
          AuthSession(token: 't', userId: 'usr_ana', role: 'resident', username: 'ana', buildingId: building).toJson()),
  });
  return Storage(await SharedPreferences.getInstance());
}

ProviderContainer _container(Storage storage, FakeHub hub) {
  final c = ProviderContainer(overrides: [
    storageProvider.overrideWithValue(storage),
    apiClientProvider.overrideWith((ref) => fakeApi(hub)),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 50));

Map<String, Object?> _unit(String id, String building) =>
    {'unit_id': id, 'unit_label': id, 'building_id': building, 'kind': 'residential'};

void main() {
  test('HubMode.fromJson reads mode, building and the live alarm flag', () {
    final m = HubMode.fromJson({'mode': 'demo', 'building_id': 'bld_007', 'live_alarm': true});
    expect(m.mode, 'demo');
    expect(m.buildingId, 'bld_007');
    expect(m.liveAlarm, isTrue);
    expect(m.isDemo, isTrue);
    final r = HubMode.fromJson({'mode': 'real', 'building_id': 'bld_live'});
    expect(r.isDemo, isFalse);
    expect(r.liveAlarm, isFalse);
  });

  test('a session on bld_live follows a demo mode to bld_007 and saves it', () async {
    final storage = await _storage(building: 'bld_live');
    final hub = FakeHub()..reply(_modePath, 200, {'mode': 'demo', 'building_id': 'bld_007', 'live_alarm': true});
    final c = _container(storage, hub);
    expect(c.read(sessionProvider)!.buildingId, 'bld_live');

    c.listen(hubModeProvider, (_, __) {});
    await _tick();

    expect(c.read(sessionProvider)!.buildingId, 'bld_007');
    expect(storage.loadSession()!.buildingId, 'bld_007');
    expect(c.read(hubModeProvider)!.liveAlarm, isTrue);
  });

  test('a failed poll keeps the building and the next poll still applies', () async {
    final storage = await _storage(building: 'bld_live');
    final hub = FakeHub()..reply(_modePath, 500, {'detail': 'down'});
    final c = _container(storage, hub);
    c.listen(hubModeProvider, (_, __) {});
    await _tick();
    expect(c.read(sessionProvider)!.buildingId, 'bld_live');
    expect(c.read(hubModeProvider), isNull);

    hub.reply(_modePath, 200, {'mode': 'demo', 'building_id': 'bld_007', 'live_alarm': false});
    await c.read(hubModeProvider.notifier).poll();
    expect(c.read(sessionProvider)!.buildingId, 'bld_007');
  });

  test('nothing polls while signed out', () async {
    final storage = await _storage();
    final hub = FakeHub()..reply(_modePath, 200, {'mode': 'demo', 'building_id': 'bld_007', 'live_alarm': false});
    final c = _container(storage, hub);
    c.listen(hubModeProvider, (_, __) {});
    await _tick();
    expect(hub.calls('GET', '/api/v1/mode'), isEmpty);
    expect(c.read(hubModeProvider), isNull);
  });

  test('login takes the building from the hub mode', () async {
    final storage = await _storage();
    final hub = FakeHub()
      ..reply('POST /api/v1/auth/token', 200, {'access_token': 'tok', 'user_id': 'usr_ana', 'role': 'resident'})
      ..reply(_modePath, 200, {'mode': 'demo', 'building_id': 'bld_007', 'live_alarm': false});
    final c = _container(storage, hub);
    await c.read(sessionProvider.notifier).login('ana');
    expect(c.read(sessionProvider)!.buildingId, 'bld_007');
    expect(storage.loadSession()!.buildingId, 'bld_007');
  });

  group('"my home" is the session building', () {
    final meJson = {
      'user_id': 'usr_ana', 'username': 'ana', 'display_name': 'Ana', 'role': 'resident',
      'units': [_unit('unit_demo', 'bld_007'), _unit('unit_live', 'bld_live')],
    };
    Map<String, Object?> profile(String id, String unit) =>
        {'id': id, 'unit_id': unit, 'display_name': id, 'is_self': false, 'needs': ['pet']};

    FakeHub hub() => FakeHub()
      ..reply('GET /api/v1/me', 200, meJson)
      ..reply('GET /api/v1/me/care-profiles', 200, [profile('cp_demo', 'unit_demo'), profile('cp_live', 'unit_live')])
      ..reply('GET /api/v1/me/household', 200, [
        {'unit_id': 'unit_demo', 'unit_label': 'D', 'members': []},
        {'unit_id': 'unit_live', 'unit_label': 'L', 'members': []},
      ]);

    test('/me, care profiles and household list only the current building', () async {
      final c = _container(await _storage(building: 'bld_007'), hub());
      c.listen(meProvider, (_, __) {});
      final me = (await c.read(meProvider.future))!;
      expect(me.units.map((u) => u.unitId), ['unit_demo']);
      expect(me.residentialUnits.map((u) => u.id), ['unit_demo']);
      expect((await c.read(careProfilesProvider.future)).map((p) => p.id), ['cp_demo']);
      expect((await c.read(householdProvider.future)).map((u) => u.unitId), ['unit_demo']);
    });

    test('a unit without a building (older hub) is kept', () {
      final me = MeProfile.fromJson({
        'user_id': 'u', 'username': 'a', 'role': 'resident',
        'units': [
          {'unit_id': 'old', 'kind': 'residential'},
          _unit('other', 'bld_live'),
        ],
      }).forBuilding('bld_007');
      expect(me.units.map((u) => u.unitId), ['old']);
      expect(me.otherUnitIds, {'other'});
    });

    test('the other building is shown after the mode flips, with nothing left from before', () async {
      final storage = await _storage(building: 'bld_007');
      final c = _container(storage, hub());
      c.listen(meProvider, (_, __) {});
      c.listen(careProfilesProvider, (_, __) {});
      expect((await c.read(careProfilesProvider.future)).map((p) => p.id), ['cp_demo']);

      await c.read(sessionProvider.notifier).switchBuilding('bld_live');
      await _tick();
      expect((await c.read(meProvider.future))!.units.map((u) => u.unitId), ['unit_live']);
      expect((await c.read(careProfilesProvider.future)).map((p) => p.id), ['cp_live']);
    });
  });
}
