import 'package:canary_resident/src/models/incident.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classification parses known layers without changing alarm state', () {
    final incident = Incident.fromJson({
      'id': 'i',
      'building_id': 'b',
      'state': 'evacuation',
      'signature': {
        'label': 'steam',
        'confidence': 0.8,
        'evidence': ['humidity rising', 12],
        'shadow_label': 'flaming_fire',
        'shadow_confidence': 0.91,
        'model_version': 'forest-v1',
        'ts': '2026-11-04T12:00:00Z'
      },
    });
    expect(incident.signature?.label, 'steam');
    expect(incident.signature?.confidence, 0.8);
    expect(incident.signature?.evidence, ['humidity rising']);
    expect(incident.signature?.shadowConfidence, 0.91);
    expect(incident.signature?.modelVersion, 'forest-v1');
    expect(incident.signature?.ts, DateTime.utc(2026, 11, 4, 12));
    expect(incident.hasClassification, isTrue);
    expect(incident.isEvacuation, isTrue);
  });

  test('classification handles malformed and unknown data safely', () {
    for (final value in [
      null,
      'broken',
      42,
      {'label': 'unknown', 'confidence': 'NaN', 'ts': 42, 'evidence': 'broken'}
    ]) {
      final incident = Incident.fromJson(
          {'id': 'i', 'building_id': 'b', 'signature': value});
      expect(incident.hasClassification, isFalse);
    }
    final signature = IncidentSignature.fromJson({
      'label': 'normal',
      'shadow_label': 'gas_leak',
      'confidence': 2,
      'shadow_confidence': -1
    });
    expect(signature.confidence, isNull);
    expect(signature.shadowConfidence, isNull);
    expect(
        Incident.fromJson({
          'id': 'i',
          'building_id': 'b',
          'signature': {'label': 'normal', 'shadow_label': 'gas_leak'}
        }).hasClassification,
        isTrue);
    for (final state in ['normal', 'false_alarm', 'resolution']) {
      expect(
          Incident.fromJson({
            'id': 'i',
            'building_id': 'b',
            'state': state,
            'signature': {'label': 'cooking'}
          }).hasClassification,
          isFalse);
    }
  });

  test('REST incident combines primary and affected zone ids', () {
    final incident = Incident.fromJson(const {
      'id': 'incident',
      'building_id': 'building',
      'primary_zone_id': 'primary',
      'affected_zone_ids': ['primary', 'secondary', 3],
    });
    expect(incident.affectedZoneIds, ['primary', 'secondary']);
    expect(incident.hazardZoneIds, {'primary', 'secondary'});
  });

  test('WebSocket incident parses affected ids and tolerates missing lists',
      () {
    final event = Incident.fromWsEvent(const {
      'incident_id': 'incident',
      'building_id': 'building',
      'affected_zone_ids': ['secondary'],
    });
    expect(event.hazardZoneIds, {'secondary'});
    final missing = Incident.fromWsEvent(const {
      'incident_id': 'incident',
      'building_id': 'building',
      'affected_zone_ids': 'invalid',
    });
    expect(missing.affectedZoneIds, isEmpty);
    expect(missing.hazardZoneIds, isEmpty);
    expect(
        Incident.fromJson(const {
          'id': 'incident',
          'building_id': 'building',
        }).affectedZoneIds,
        isEmpty);
  });
}
