import 'package:canary_resident/src/logic/route_selection.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:flutter_test/flutter_test.dart';

EvacuationRoute route(String id, List<String> path, {String? fromZoneId}) =>
    EvacuationRoute(
      id: id,
      label: id,
      path: path,
      toAssemblyPointId: 'assembly',
      fromZoneId: fromZoneId,
    );

EvacuationInfo info(List<EvacuationRoute> routes) =>
    EvacuationInfo(routes: routes, assemblyPoints: const []);

void main() {
  test('returns null when no routes exist', () {
    expect(selectRoute(info([]), hazardZoneIds: {'hazard'}), isNull);
  });

  test('checks the entire path, not just its start', () {
    final through = route('through', ['start', 'hazard', 'exit']);
    final safe = route('safe', ['start', 'hall', 'exit']);
    final choice = selectRoute(info([through, safe]), hazardZoneIds: {'hazard'});
    expect(choice?.route.id, 'safe');
    expect(choice?.safety, RouteSafety.clear);
    expect(choice?.crossesHazard, isFalse);
  });

  test('prefers user zone among non-crossing routes then API order', () {
    final other = route('other', ['a', 'exit'], fromZoneId: 'other');
    final mine = route('mine', ['b', 'exit'], fromZoneId: 'home');
    final mineSecond = route('mine2', ['c', 'exit'], fromZoneId: 'home');
    expect(
      selectRoute(
        info([other, mine, mineSecond]),
        hazardZoneIds: {'hazard'},
        userZoneId: 'home',
      )?.route.id,
      'mine',
    );
    expect(
      selectRoute(info([other, mine]), hazardZoneIds: {'hazard'}, userZoneId: 'unknown')?.route.id,
      'other',
    );
  });

  test('safe route outranks a crossing route from the user zone', () {
    final mine = route('mine', ['home', 'hazard', 'exit'], fromZoneId: 'home');
    final other = route('other', ['other', 'exit'], fromZoneId: 'other');
    expect(
      selectRoute(
        info([mine, other]),
        hazardZoneIds: {'hazard'},
        userZoneId: 'home',
      )?.route.id,
      'other',
    );
  });

  test('returns and flags best route if every route crosses', () {
    final other = route('other', ['other', 'hazard']);
    final mine = route('mine', ['home', 'hazard'], fromZoneId: 'home');
    final choice = selectRoute(
      info([other, mine]),
      hazardZoneIds: {'hazard'},
      userZoneId: 'home',
    );
    expect(choice?.route.id, 'mine');
    expect(choice?.crossesHazard, isTrue);
  });

  test('allows leaving hazard only at path index zero', () {
    final leaving = route('leaving', ['hazard', 'exit']);
    final returning = route('returning', ['hazard', 'exit', 'hazard']);
    expect(
      selectRoute(
        info([returning, leaving]),
        hazardZoneIds: {'hazard'},
        userZoneId: 'hazard',
      )?.route.id,
      'leaving',
    );
    expect(
      selectRoute(info([leaving]), hazardZoneIds: {'hazard'})?.crossesHazard,
      isTrue,
    );
    expect(
      selectRoute(
        info([leaving]),
        hazardZoneIds: {'hazard'},
        userZoneId: 'other',
      )?.crossesHazard,
      isTrue,
    );
    expect(
      selectRoute(
        info([returning]),
        hazardZoneIds: {'hazard'},
        userZoneId: 'hazard',
      )?.crossesHazard,
      isTrue,
    );
  });

  test('an empty path has unknown safety', () {
    final empty = route('empty', [], fromZoneId: 'home');
    expect(
      selectRoute(info([empty]), hazardZoneIds: {'hazard'})?.safety,
      RouteSafety.unknown,
    );
  });

  test('missing hazard ids give unknown safety', () {
    final choice = selectRoute(info([route('route', ['home', 'exit'])]));
    expect(choice?.safety, RouteSafety.unknown);
    expect(choice?.crossesHazard, isFalse);
  });

  test('checks every affected hazard zone', () {
    final through = route('through', ['home', 'secondary', 'exit']);
    final safe = route('safe', ['home', 'hall', 'exit']);
    final choice = selectRoute(info([through, safe]),
      hazardZoneIds: {'primary', 'secondary'});
    expect(choice?.route.id, 'safe');
    expect(selectRoute(info([through]),
      hazardZoneIds: {'primary', 'secondary'})?.safety, RouteSafety.crosses);
  });

  test('ranks clear before unknown before crossing, then user zone', () {
    final crossing = route('crossing', ['home', 'hazard'], fromZoneId: 'home');
    final unknown = route('unknown', [], fromZoneId: 'home');
    final clear = route('clear', ['other', 'exit'], fromZoneId: 'other');
    expect(selectRoute(info([crossing, unknown, clear]),
      hazardZoneIds: {'hazard'}, userZoneId: 'home')?.route.id, 'clear');
    expect(selectRoute(info([crossing, unknown]),
      hazardZoneIds: {'hazard'}, userZoneId: 'home')?.route.id, 'unknown');
  });

  test('map path ids can mark a route as crossing', () {
    final parsed = EvacuationInfo.fromJson(const {
      'routes': [
        {'id': 'through', 'to_assembly_point_id': 'assembly',
          'path': ['home', {'id': 'hazard'}, 'exit']},
      ],
    });
    expect(parsed.routes.single.path, ['home', 'hazard', 'exit']);
    expect(selectRoute(parsed, hazardZoneIds: {'hazard'})?.safety,
      RouteSafety.crosses);
  });
}
