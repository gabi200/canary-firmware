import 'package:canary_resident/src/models/incident.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('REST incident combines primary and affected zone ids', () {
    final incident = Incident.fromJson(const {
      'id': 'incident', 'building_id': 'building',
      'primary_zone_id': 'primary',
      'affected_zone_ids': ['primary', 'secondary', 3],
    });
    expect(incident.affectedZoneIds, ['primary', 'secondary']);
    expect(incident.hazardZoneIds, {'primary', 'secondary'});
  });

  test('WebSocket incident parses affected ids and tolerates missing lists', () {
    final event = Incident.fromWsEvent(const {
      'incident_id': 'incident', 'building_id': 'building',
      'affected_zone_ids': ['secondary'],
    });
    expect(event.hazardZoneIds, {'secondary'});
    final missing = Incident.fromWsEvent(const {
      'incident_id': 'incident', 'building_id': 'building',
      'affected_zone_ids': 'invalid',
    });
    expect(missing.affectedZoneIds, isEmpty);
    expect(missing.hazardZoneIds, isEmpty);
    expect(Incident.fromJson(const {
      'id': 'incident', 'building_id': 'building',
    }).affectedZoneIds, isEmpty);
  });
}
