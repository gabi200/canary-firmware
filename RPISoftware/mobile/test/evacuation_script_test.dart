import 'package:canary_resident/l10n/gen/app_localizations.dart';
import 'package:canary_resident/src/logic/evacuation_script.dart';
import 'package:canary_resident/src/logic/route_selection.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const waypoints = [
    Waypoint(id: 'lobby', label: 'Lobby', hint: 'Leave by the main doors.'),
    Waypoint(id: 'stairs', label: 'Stairs', hint: 'Go down to ground floor.'),
  ];

  Future<AppLocalizations> l10nFor(String languageCode) =>
      AppLocalizations.delegate.load(Locale(languageCode));

  test('builds the English crossing-route script in evacuation order', () async {
    final l10n = await l10nFor('en');

    final script = buildEvacuationScript(
      l10n: l10n,
      hazardDont: "Don't use the lift.",
      waypoints: waypoints,
      avoidZoneName: 'Kitchen',
      assemblyPointName: 'Car park',
      safety: RouteSafety.crosses,
    );

    expect(script, startsWith("Don't use the lift. Avoid: Kitchen."));
    expect(script, contains('This route passes near the hazard.'));
    expect(script, contains('Step 1 of 2: Lobby. Leave by the main doors.'));
    expect(script, endsWith('Then go to the assembly point: Car park.'));
  });

  test('builds the Romanian unknown-route script with localized steps', () async {
    final l10n = await l10nFor('ro');

    final script = buildEvacuationScript(
      l10n: l10n,
      hazardDont: 'Nu folosiți liftul.',
      waypoints: waypoints,
      avoidZoneName: 'Bucătărie',
      assemblyPointName: 'Parcare',
      safety: RouteSafety.unknown,
    );

    expect(script, contains('Evitați: Bucătărie.'));
    expect(script, contains('Nu am putut verifica această rută față de pericol.'));
    expect(script, contains('Pasul 1 din 2: Lobby. Leave by the main doors.'));
    expect(script, endsWith('Apoi mergeți la punctul de adunare: Parcare.'));
  });

  test('uses the fallback instruction when no route is available', () async {
    final l10n = await l10nFor('en');

    final script = buildEvacuationScript(
      l10n: l10n,
      hazardDont: "Don't use the lift.",
      waypoints: const [],
      safety: null,
    );

    expect(script, "Don't use the lift. Leave by the nearest safe exit. Do not use the lift.");
  });
}
