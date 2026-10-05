import 'package:canary_resident/src/models/evacuation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses structured waypoints and default fields', () {
    final info = EvacuationInfo.fromJson(const {
      'assembly_points': [
        {'id': 'assembly', 'label': 'Front courtyard'},
      ],
      'routes': [
        {
          'id': 'route',
          'label': 'Safe way',
          'to_assembly_point_id': 'assembly',
          'path': ['zone_home', 'stairwell_main', 'assembly'],
          'waypoints': [
            {
              'id': 'zone_home',
              'label': 'Your unit',
              'kind': 'apartment',
              'hint': 'Leave now',
            },
            {'id': 'stairwell_main', 'label': 'Main stairs'},
            {'id': 'assembly', 'label': 'Courtyard', 'kind': 'assembly_point'},
          ],
        },
      ],
    });

    final route = info.routes.single;
    expect(route.path, ['zone_home', 'stairwell_main', 'assembly']);
    expect(route.waypoints.map((w) => w.label), [
      'Your unit',
      'Main stairs',
      'Courtyard',
    ]);
    expect(route.waypoints.first.kind, 'apartment');
    expect(route.waypoints.first.hint, 'Leave now');
    expect(route.waypoints[1].kind, 'waypoint');
    expect(route.waypoints[1].hint, '');
    expect(route.waypoints.last.kind, 'assembly_point');
  });

  test('legacy path builds human labels and resolves assembly label', () {
    final info = EvacuationInfo.fromJson(const {
      'assembly_points': [
        {'id': 'assembly_main', 'label': 'Front courtyard'},
      ],
      'routes': [
        {
          'id': 'legacy',
          'to_assembly_point_id': 'assembly_main',
          'path': ['zone_home', 'stairwell_main', 'assembly_main'],
        },
      ],
    });

    final route = info.routes.single;
    expect(route.path, ['zone_home', 'stairwell_main', 'assembly_main']);
    expect(route.waypoints.map((w) => w.label), [
      'Zone home',
      'Stairwell main',
      'Front courtyard',
    ]);
    expect(route.waypoints.map((w) => w.kind), [
      'waypoint',
      'waypoint',
      'waypoint',
    ]);
  });

  test('empty waypoint list falls back and unknown assembly is humanized', () {
    final info = EvacuationInfo.fromJson(const {
      'routes': [
        {
          'id': 'legacy',
          'to_assembly_point_id': 'assembly_side',
          'path': ['exit_side', 'assembly_side'],
          'waypoints': [],
        },
      ],
    });
    expect(info.routes.single.waypoints.map((w) => w.label), [
      'Exit side',
      'Assembly side',
    ]);
  });

  test('malformed routes and waypoints do not discard valid routes', () {
    final info = EvacuationInfo.fromJson(const {
      'assembly_points': [
        {'id': 'assembly', 'label': 'Courtyard', 'lat': 'bad', 'lon': 24},
      ],
      'routes': [
        {'to_assembly_point_id': 'assembly', 'path': ['ignored']},
        {'id': 'missing_destination', 'path': ['ignored']},
        'not a route',
        {
          'id': 'valid', 'to_assembly_point_id': 'assembly',
          'path': ['home', {'id': 'hazard'}, 42, {'wrong': 'value'}],
          'waypoints': [
            'not a waypoint',
            {'label': 'Missing id'},
            {'id': 'home', 'label': 'Home'},
          ],
        },
        {'id': 'also_valid', 'to_assembly_point_id': 'assembly',
          'path': 'wrong type', 'waypoints': 'wrong type'},
      ],
    });
    expect(info.routes.map((r) => r.id), ['valid', 'also_valid']);
    expect(info.routes.first.path, ['home', 'hazard']);
    expect(info.routes.first.waypoints.map((w) => w.id), ['home']);
    expect(info.routes.last.path, isEmpty);
    expect(info.routes.last.waypoints, isEmpty);
    expect(info.assemblyPoints.single.lat, isNull);
    expect(info.assemblyPoints.single.lon, 24);
  });

  test('wrong top-level collection types become empty lists', () {
    final info = EvacuationInfo.fromJson(const {
      'routes': 'wrong', 'assembly_points': {'id': 'wrong'},
    });
    expect(info.routes, isEmpty);
    expect(info.assemblyPoints, isEmpty);
  });
}
