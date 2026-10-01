import 'package:canary_resident/l10n/gen/app_localizations.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/ui/widgets/route_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders ordered directions, destination icon, and avoid instruction',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RouteLine(
            avoidZoneName: 'Kitchen',
            waypoints: [
              Waypoint(id: 'lobby', label: 'Lobby', hint: 'Use the main doors.'),
              Waypoint(id: 'assembly', label: 'Assembly point'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Start here'), findsOneWidget);
    expect(find.text('Lobby'), findsOneWidget);
    expect(find.text('Use the main doors.'), findsOneWidget);
    expect(find.text('Avoid: Kitchen'), findsOneWidget);
    expect(find.text('Assembly point'), findsOneWidget);
    expect(find.byIcon(Icons.flag), findsOneWidget);
  });

  testWidgets('has no visual directions for an empty route', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: RouteLine(waypoints: [])),
      ),
    );

    expect(find.text('Start here'), findsNothing);
    expect(find.byIcon(Icons.flag), findsNothing);
  });
}
