import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../state/providers.dart';
import '../state/scope_providers.dart';
import 'alarm_screen.dart';
import 'widgets/hazard_banner.dart';
import 'widgets/home_status_section.dart';
import 'widgets/unit_scope_bar.dart';

/// One room of the resident's home, opened from its tile: the room card (vital
/// chips, a row per sensor; a sensor opens its sheet with charts and the test
/// buttons) under an alarm banner when an incident is in the room.
class RoomScreen extends ConsumerWidget {
  const RoomScreen({super.key, required this.zoneId, required this.title, required this.sheetLabel});
  final String zoneId;

  /// The room's name in the app bar, and in the sensor sheet.
  final String title;
  final String sheetLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(summaryProvider).summary?.zones.where((z) => z.zoneId == zoneId).firstOrNull;
    final alarm = ref
        .watch(incidentControllerProvider)
        .incidents
        .where((i) => i.isAlarming && i.hazardZoneIds.contains(zoneId))
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(summaryProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (alarm != null) ...[
              HazardBanner(
                incident: alarm,
                zoneLabel: title,
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => AlarmScreen(incidentId: alarm.id))),
              ),
              const SizedBox(height: 16),
            ],
            if (zone == null)
              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else
              RoomCard(zone: zone, label: title, sheetLabel: sheetLabel, showLabel: false),
          ],
        ),
      ),
    );
  }
}

/// "Toți senzorii": the full home status one tap away from home: the overall
/// card, the List / Sketch switch and every room card, under the apartment
/// picker when the resident has several homes.
class HomeSensorsScreen extends ConsumerWidget {
  const HomeSensorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(summaryScopeProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.allSensors)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(summaryProvider.notifier).refresh(),
        child: CustomScrollView(
          slivers: [
            if (scope.hasPicker) UnitScopeHeader(scope: scope),
            const SliverPadding(
              padding: EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(child: HomeStatusSection()),
            ),
          ],
        ),
      ),
    );
  }
}
