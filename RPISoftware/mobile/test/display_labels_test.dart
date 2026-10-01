import 'package:canary_resident/src/logic/display_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses a zone label or humanizes its identifier', () {
    expect(prettyZone({'zone_kitchen': 'Kitchen'}, 'zone_kitchen'), 'Kitchen');
    expect(prettyZone(null, 'zone_kitchen'), 'Kitchen');
  });

  test('turns canonical incident states into readable text', () {
    expect(incidentStateLabel('evacuation'), 'Evacuate now');
  });
}
