import 'package:canary_resident/src/models/check_in.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/dashboard_providers.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/alarm_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/alarm_fixtures.dart';

// wakelock_plus talks over Pigeon message channels, not a MethodChannel.
const _wakelockChannels = [
  'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
  'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.isEnabled',
];
const _urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    for (final name in _wakelockChannels) {
      messenger.setMockMessageHandler(name, (_) async =>
          const StandardMessageCodec().encodeMessage(<Object?>[false]));
    }
    messenger.setMockMethodCallHandler(_urlLauncherChannel, (_) async => false);
  });

  tearDownAll(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    for (final name in _wakelockChannels) {
      messenger.setMockMessageHandler(name, null);
    }
    messenger.setMockMethodCallHandler(_urlLauncherChannel, null);
  });

  for (final hazard in <({String type, String label, String dont})>[
    (
      type: 'combustible_gas',
      label: 'Gas leak',
      dont: "Don't use the lift, light switches, or open flames.",
    ),
    (
      type: 'particulate',
      label: 'Smoke / particulates',
      dont: "Stay low under smoke. Don't use the lift.",
    ),
    (
      type: 'water_leak',
      label: 'Water leak',
      dont: "Don't touch electrical devices or switches near water.",
    ),
    (
      type: 'co',
      label: 'Carbon monoxide',
      dont: "Don't stay inside. Get to fresh air now.",
    ),
  ]) {
    testWidgets('shows ${hazard.label} and its do-not instruction', (tester) async {
      _usePhoneSurface(tester);
      await _pumpAlarm(
        tester,
        incident: evacuationIncident(hazardType: hazard.type),
        evacuation: evacuationForSafety('clear'),
      );

      expect(find.textContaining(hazard.label), findsOneWidget);
      expect(find.text(hazard.dont), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
    });
  }

  testWidgets('shows the red route warning when the selected route crosses the hazard',
      (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, evacuation: evacuationForSafety('crosses'));

    expect(
      find.text('This route passes near the hazard. Use another marked exit if you can, and call 112.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
  });

  testWidgets('shows the amber route warning when route safety is unknown', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, evacuation: evacuationForSafety('unknown'));

    expect(
      find.text("We couldn't check this route against the hazard. Follow the marked exits, stay away from the hazard, and call 112 if unsure."),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
  });

  testWidgets('does not show a route warning for a clear route', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, evacuation: evacuationForSafety('clear'));

    expect(find.textContaining('This route passes near the hazard.'), findsNothing);
    expect(find.textContaining("We couldn't check this route against the hazard."), findsNothing);
  });

  testWidgets('shows the offline connection chip', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, connected: false);

    expect(find.text('Offline · showing saved route'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
  });

  testWidgets('shows the recent live connection chip', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(
      tester,
      connected: true,
      lastMessageAt: DateTime.now().subtract(const Duration(seconds: 20)),
    );

    expect(find.text('Live · updated 20 s ago'), findsOneWidget);
    expect(find.byIcon(Icons.wifi), findsOneWidget);
  });

  testWidgets('checks in as safe outside and lets the resident change it', (tester) async {
    _usePhoneSurface(tester);
    final controller = await _pumpAlarm(tester);

    await tester.tap(find.text("I'm out and safe"));
    await tester.pump();

    expect(controller.submissions, [(incidentId, CheckInStatus.safeOutside)]);
    expect(find.text("Checked in: I'm safe / evacuated"), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);

    await tester.tap(find.text('Change'));
    await tester.pump();

    expect(find.text("I'm out and safe"), findsOneWidget);
    expect(find.text('I need help'), findsOneWidget);
  });

  testWidgets('keeps the primary action available at 2x text scale without overflow',
      (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, textScaler: const TextScaler.linear(2));

    expect(find.text("I'm out and safe"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses an actionable fallback when no evacuation routes are available',
      (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(
      tester,
      evacuation: const EvacuationInfo(routes: [], assemblyPoints: []),
    );

    expect(find.textContaining('Gas leak'), findsOneWidget);
    expect(find.text("I'm out and safe"), findsOneWidget);
    expect(find.text('Leave by the nearest safe exit. Do not use the lift.'), findsOneWidget);
  });

  testWidgets('golden: gas incident with a clear route while live', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(
      tester,
      connected: true,
      lastMessageAt: DateTime.now().subtract(const Duration(seconds: 20)),
      evacuation: evacuationForSafety('clear'),
    );

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/alarm_gas_clear_live.png'),
    );
  }, tags: ['golden']);

  testWidgets('golden: crossing route warning while offline', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, connected: false, evacuation: evacuationForSafety('crosses'));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/alarm_crosses_offline.png'),
    );
  }, tags: ['golden']);

  testWidgets('golden: two-times text scale', (tester) async {
    _usePhoneSurface(tester);
    await _pumpAlarm(tester, textScaler: const TextScaler.linear(2));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/alarm_text_scale_2x.png'),
    );
  }, tags: ['golden']);
}

void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1290, 2796);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<FakeIncidentController> _pumpAlarm(
  WidgetTester tester, {
  Incident? incident,
  EvacuationInfo? evacuation,
  bool connected = true,
  DateTime? lastMessageAt,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  SharedPreferences.setMockInitialValues({});
  final storage = Storage(await SharedPreferences.getInstance());
  final controller = FakeIncidentController(
    storage: storage,
    initialState: IncidentsState(
      incidents: [incident ?? evacuationIncident()],
      connected: connected,
      lastMessageAt: lastMessageAt,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageProvider.overrideWithValue(storage),
        incidentControllerProvider.overrideWith((ref) => controller),
        evacuationProvider.overrideWith((ref) async => evacuation ?? evacuationForSafety('clear')),
        zoneLabelsProvider.overrideWith((ref) async => const {hazardZoneId: 'Kitchen'}),
      ],
      child: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(textScaler: textScaler),
        child: const MaterialApp(home: AlarmScreen(incidentId: incidentId)),
      ),
    ),
  );
  await tester.pump();
  return controller;
}
