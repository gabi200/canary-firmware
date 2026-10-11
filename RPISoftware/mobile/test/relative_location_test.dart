// Where the danger is from the resident's point of view, the rooms on the
// alarm screen's plan, and the advice for each "Unde ești acum?" answer.
import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/logic/relative_location.dart';
import 'package:canary_resident/src/models/check_in.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/models/zone_info.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

ZoneInfo _zone(String id, String label, String unit, String? unitLabel,
        {String? floor = 'flr_03', String? floorLabel = 'Etaj 3', String kind = 'kitchen', double? x, double? y}) =>
    ZoneInfo.fromJson({
      'id': id, 'label': label, 'unit_id': unit, 'unit_label': unitLabel, 'floor_id': floor,
      'floor_label': floorLabel, 'kind': kind, 'pos_x': x, 'pos_y': y,
      if (unit == 'common') 'unit_kind': 'common',
    });

/// bld_007 as the hub sends it: Ap. 12 and Ap. 13 on Etaj 3 with the common
/// hallway and boiler room, and Ap. 52 on Etaj 5.
final _zones = [
  _zone('zone_kitchen', 'Bucătărie', 'unit_0312', 'Ap. 12', x: 2, y: 2),
  _zone('zone_living_12', 'Living', 'unit_0312', 'Ap. 12', kind: 'living_room', x: 5, y: 3),
  _zone('zone_kitchen_13', 'Bucătărie', 'unit_0313', 'Ap. 13', x: 12, y: 2),
  _zone('zone_hallway', 'Hol scară', 'common', 'Spații comune', kind: 'hallway', x: 5, y: 5),
  _zone('zone_boiler', 'Centrală termică', 'common', 'Spații comune', kind: 'boiler', floor: null, floorLabel: null),
  _zone('zone_kitchen_52', 'Bucătărie', 'unit_0552', 'Ap. 52', floor: 'flr_05', floorLabel: 'Etaj 5', x: 2, y: 2),
];
final _byId = {for (final z in _zones) z.id: z};

ResidentHome _home(List<String> units) =>
    residentHome([for (final u in units) (id: u, label: null, floorLabel: null)], _zones);

Incident _gas(String? zone, {List<String> affected = const [], String state = 'alarm'}) => Incident(
    id: 'inc', buildingId: 'bld_007', hazardType: 'combustible_gas', severity: 'critical', state: state,
    primaryZoneId: zone, affectedZoneIds: affected);

void main() {
  final ana = _home(['unit_0312']);
  final radu = _home(['unit_0313']);
  final upstairs = _home(['unit_0552']);

  group('resident home', () {
    test('labels and floors come from the zone list when /me lacks them', () {
      expect(ana.title, 'Ap. 12 · Etaj 3');
      expect(ana.units.single.floorId, 'flr_03');
      final fromMe = residentHome([(id: 'unit_0312', label: 'Ap. 12', floorLabel: 'Floor 3')], _zones);
      expect(fromMe.title, 'Ap. 12 · Floor 3', reason: '/me wins over the zone list');
    });

    test('several homes: labels only; none: no title', () {
      expect(_home(['unit_0312', 'unit_0552']).title, 'Ap. 12, Ap. 52');
      expect(ResidentHome.none.title, isNull);
      expect(_home(['unit_0312', 'unit_0312']).units, hasLength(1));
    });

    test('floors compare by id, else by label, else unknown', () {
      expect(ana.sharesFloor(_byId['zone_kitchen_13']!), isTrue);
      expect(ana.sharesFloor(_byId['zone_kitchen_52']!), isFalse);
      expect(ana.sharesFloor(_byId['zone_boiler']!), isNull);
      expect(ResidentHome.none.sharesFloor(_byId['zone_kitchen']!), isNull);
    });
  });

  group('where the danger is', () {
    test('in your home: the room', () {
      expect(hazardWhere(_gas('zone_kitchen'), _byId, ana),
          const HazardWhere(HazardPlace.home, zoneId: 'zone_kitchen', detail: 'Bucătărie'));
    });

    test('another apartment on your floor', () {
      expect(hazardWhere(_gas('zone_kitchen'), _byId, radu),
          const HazardWhere(HazardPlace.myFloor, zoneId: 'zone_kitchen', detail: 'Ap. 12'));
    });

    test('a common area on your floor', () {
      expect(hazardWhere(_gas('zone_hallway'), _byId, ana),
          const HazardWhere(HazardPlace.myFloorCommon, zoneId: 'zone_hallway', detail: 'Hol scară'));
    });

    test('another floor: which floor and which apartment', () {
      expect(hazardWhere(_gas('zone_kitchen'), _byId, upstairs),
          const HazardWhere(HazardPlace.otherFloor, zoneId: 'zone_kitchen', detail: 'Etaj 3 · Ap. 12'));
      expect(hazardWhere(_gas('zone_kitchen_52'), _byId, ana).detail, 'Etaj 5 · Ap. 52');
    });

    test('a common area whose floor is unknown', () {
      expect(hazardWhere(_gas('zone_boiler'), _byId, ana),
          const HazardWhere(HazardPlace.commonArea, zoneId: 'zone_boiler', detail: 'Centrală termică'));
    });

    test('home not known yet: the apartment, without "your floor"', () {
      expect(hazardWhere(_gas('zone_kitchen'), _byId, ResidentHome.none),
          const HazardWhere(HazardPlace.building, zoneId: 'zone_kitchen', detail: 'Ap. 12'));
    });

    test('danger that reaches your home wins over where it started', () {
      final spread = _gas('zone_kitchen_13', affected: ['zone_hallway', 'zone_living_12']);
      expect(hazardWhere(spread, _byId, ana),
          const HazardWhere(HazardPlace.home, zoneId: 'zone_living_12', detail: 'Living'));
      expect(hazardWhere(spread, _byId, radu).place, HazardPlace.home);
      expect(hazardWhere(spread, _byId, upstairs).detail, 'Etaj 3 · Ap. 13');
    });

    test('several homes: the room says which one', () {
      expect(hazardWhere(_gas('zone_kitchen'), _byId, _home(['unit_0312', 'unit_0552'])).detail, 'Bucătărie · Ap. 12');
    });

    test('unknown zones, or none: unknown', () {
      expect(hazardWhere(_gas('zone_nowhere'), _byId, ana).place, HazardPlace.unknown);
      expect(hazardWhere(_gas(null), _byId, ana).place, HazardPlace.unknown);
      expect(hazardWhere(_gas('zone_kitchen'), const {}, ana).place, HazardPlace.unknown);
    });

    test('one line in Romanian and English', () {
      final ro = lookupAppLocalizations(const Locale('ro'));
      final en = lookupAppLocalizations(const Locale('en'));
      String line(AppLocalizations l, Incident i, ResidentHome h) => l.hazardWhereText(hazardWhere(i, _byId, h));
      expect(line(ro, _gas('zone_kitchen'), ana), 'În locuința ta: Bucătărie');
      expect(line(ro, _gas('zone_kitchen'), radu), 'Pe etajul tău: Ap. 12');
      expect(line(ro, _gas('zone_hallway'), ana), 'Pe etajul tău: Hol scară (spațiu comun)');
      expect(line(ro, _gas('zone_kitchen'), upstairs), 'Pe alt etaj: Etaj 3 · Ap. 12');
      expect(line(ro, _gas('zone_boiler'), ana), 'Într-un spațiu comun: Centrală termică');
      expect(line(en, _gas('zone_kitchen'), radu), 'On your floor: Ap. 12');
      expect(line(en, _gas('zone_nowhere'), ana), 'In the building (exact place not known yet)');
      expect(en.youAre(ana.title!), 'You: Ap. 12 · Etaj 3');
    });
  });

  group('affected rooms', () {
    test('affected rooms: the source first, marked when they are yours', () {
      final rooms = affectedRooms(_gas('zone_kitchen', affected: ['zone_hallway', 'zone_kitchen']), _byId, ana);
      expect([for (final r in rooms) (r.zone.id, r.source, r.mine)], [
        ('zone_kitchen', true, true),
        ('zone_hallway', false, false),
      ]);
      expect(affectedRooms(_gas('zone_kitchen'), _byId, radu).single.mine, isFalse);
    });
  });

  group('"Unde ești acum?" advice', () {
    test('outside: stay out; elsewhere: nearest stairs', () {
      for (final place in HazardPlace.values) {
        expect(whereAdvice(ResidentLocation.outside, place, evacuation: true), WhereAdvice.stayOut);
        expect(whereAdvice(ResidentLocation.building, place, evacuation: false), WhereAdvice.leaveBuilding);
      }
    });

    test('home: leave now when the danger is in it; else by the evacuation order', () {
      expect(whereAdvice(ResidentLocation.home, HazardPlace.home, evacuation: false), WhereAdvice.leaveHomeNow);
      expect(whereAdvice(ResidentLocation.home, HazardPlace.myFloor, evacuation: true), WhereAdvice.leaveHome);
      expect(whereAdvice(ResidentLocation.home, HazardPlace.otherFloor, evacuation: false), WhereAdvice.getReady);
    });

    test('the assembly point is named when known', () {
      final ro = lookupAppLocalizations(const Locale('ro'));
      expect(ro.whereAdviceText(WhereAdvice.stayOut, assemblyPoint: 'Parcare față'),
          startsWith('Rămâi afară și mergi la punctul de adunare: Parcare față.'));
      expect(ro.whereAdviceText(WhereAdvice.stayOut), startsWith('Rămâi afară, departe de clădire.'));
    });

    test('answers keep the backend tokens', () {
      expect(ResidentLocation.values.map((l) => l.token), ['home', 'building', 'outside']);
      expect(ResidentLocation.fromToken('building'), ResidentLocation.building);
      expect(ResidentLocation.fromToken('roof'), isNull);
    });
  });
}
