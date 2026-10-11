import 'dart:io';

import 'package:canary_resident/src/logic/safety_signs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every ISO 7010 sign has its bundled asset', () {
    for (final sign in SafetySign.values) {
      expect(File(sign.asset).existsSync(), isTrue, reason: sign.asset);
    }
  });

  test('hazards map to the right ISO 7010 signs', () {
    expect(hazardSign('combustible_gas'), SafetySign.w021);
    expect(hazardSign('co'), SafetySign.w016);
    expect(hazardSign('water_leak'), SafetySign.w011);
    expect(hazardSign('particulate'), SafetySign.w001);
    expect(hazardAdviceSigns('combustible_gas'),
        [SafetySign.p020, SafetySign.p031, SafetySign.p003]);
    expect(hazardAdviceSigns('unknown'), [SafetySign.p020]);
  });
}
