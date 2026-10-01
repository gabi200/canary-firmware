import 'package:canary_resident/src/logic/floor_plan_layout.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/models/zone.dart';
import 'package:canary_resident/src/ui/widgets/floor_plan_schematic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _zones = [
  ZoneInfo(id: 'zone_kitchen', floorId: 'flr_03', unitId: null, label: 'Kitchen', kind: 'room', x: 2, y: 2),
  ZoneInfo(id: 'zone_bedroom', floorId: 'flr_03', unitId: null, label: 'Bedroom', kind: 'room', x: 8, y: 2),
  ZoneInfo(id: 'zone_hallway', floorId: 'flr_03', unitId: null, label: 'Hallway', kind: 'hallway', x: 5, y: 5),
  ZoneInfo(id: 'zone_boiler', floorId: 'flr_03', unitId: null, label: 'Boiler', kind: 'room', x: 2, y: 8),
];
const _route = [
  Waypoint(id: 'zone_hallway', label: 'Hallway', kind: 'zone'),
  Waypoint(id: 'stairwell_main', label: 'Stairs', kind: 'stairwell'),
  Waypoint(id: 'exit_front', label: 'Exit', kind: 'exit'),
  Waypoint(id: 'ap_main', label: 'Assembly', kind: 'assembly'),
];

void main() {
  testWidgets('schematic exposes one descriptive semantics label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(400, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 360,
        child: FloorPlanSchematic(
          layout: buildFloorPlanLayout(_zones, _route, {'zone_kitchen'}),
          startLabel: 'Start',
          notToScaleLabel: 'Schematic · not to scale',
          assemblyLabel: 'Assembly',
          semanticsLabel: 'Schematic evacuation route from hallway to assembly point; kitchen hazard',
        ),
      )),
    ));
    expect(find.bySemanticsLabel(
      'Schematic evacuation route from hallway to assembly point; kitchen hazard'), findsOneWidget);
    expect(find.byType(FloorPlanSchematic), findsOneWidget);
    handle.dispose();
  });

  testWidgets('empty route and no-zone route paint without exceptions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final layout in [
      buildFloorPlanLayout(_zones, [], {}),
      buildFloorPlanLayout([], _route, {}),
    ]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
        width: 360,
        child: FloorPlanSchematic(
          layout: layout,
          startLabel: 'Start',
          notToScaleLabel: 'Schematic · not to scale',
          assemblyLabel: 'Assembly',
          semanticsLabel: 'Schematic route',
        ),
      ))));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('seed floor plan golden', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(
      child: RepaintBoundary(child: SizedBox(
        width: 360,
        child: FloorPlanSchematic(
          layout: buildFloorPlanLayout(_zones, _route, {'zone_kitchen'}),
          startLabel: 'Start',
          notToScaleLabel: 'Schematic · not to scale',
          assemblyLabel: 'Assembly',
          semanticsLabel: 'Schematic route',
        ),
      )),
    ))));
    await expectLater(find.byType(FloorPlanSchematic),
        matchesGoldenFile('goldens/floor_plan_seed.png'));
  }, tags: ['golden']);
}
