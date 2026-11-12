import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../logic/relative_location.dart';
import '../models/incident.dart';
import '../models/zone_info.dart';
import '../state/building_status.dart';
import '../state/dashboard_providers.dart';
import '../state/incident_controller.dart';
import '../state/location_providers.dart';
import '../state/providers.dart';
import '../state/scope_providers.dart';
import '../theme.dart';
import 'alarm_screen.dart';
import 'room_screen.dart';
import 'widgets/care_hint_card.dart';
import 'widgets/classification_text.dart';
import 'widgets/home_banner.dart';
import 'widgets/mode_strip.dart';
import 'widgets/room_tiles.dart';
import 'widgets/safety_sign.dart';
import 'widgets/status_hero.dart';
import 'widgets/status_pill.dart';
import 'widgets/unit_scope_bar.dart';

/// The resident's home, status first: their apartment in the app bar, one big
/// status banner, a tile per room ("Camerele mele") and a short building
/// strip. Both sections fold away, and a room's sensors can open inline; the
/// full sensor list and sketch are one tap away ("Toți senzorii").
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const roomsSection = 'rooms';
  static const buildingSection = 'building';

  void _openAlarm(BuildContext context, String incidentId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AlarmScreen(incidentId: incidentId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(incidentControllerProvider);

    // Auto-surface the emergency screen when the building enters an alarming state.
    ref.listen<IncidentsState>(incidentControllerProvider, (prev, next) {
      final wasAlarming = prev?.activeAlarm != null;
      final alarm = next.activeAlarm;
      if (!wasAlarming && alarm != null) {
        _openAlarm(context, alarm.id);
      }
    });

    final l10n = context.l10n;
    // One status for the banner: verifying stays calm (no alarm screen), all
    // clear only with no open incident and the hub ok.
    final status = buildingStatusOf(state, ref.watch(summaryProvider));
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;
    // Only a resident of two or more apartments gets the picker.
    final scope = ref.watch(summaryScopeProvider);
    final home = ref.watch(residentHomeProvider);
    final infos = {for (final z in ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[]) z.id: z};
    final fold = ref.watch(homeFoldProvider);
    final open = [
      for (final i in state.incidents)
        if (!i.isClosed) i
    ];
    HazardWhere whereOf(Incident i) => hazardWhere(i, infos, home);

    final rooms = [
      for (final r in scope.shown)
        (
          room: r,
          sheetLabel: scope.sheetLabelOf(r),
          kind: infos[r.zoneId]?.kind,
          common: infos[r.zoneId]?.isCommon ?? (r.zone.unitId?.toLowerCase().contains('common') ?? false),
          incident: open.where((i) => i.hazardZoneIds.contains(r.zoneId)).firstOrNull,
        ),
    ]..sort(compareRoomTiles);
    final roomsOpen = !fold.collapsed.contains(roomsSection);
    final buildingOpen = !fold.collapsed.contains(buildingSection);
    final foldCtl = ref.read(homeFoldProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        // The resident's home ("Ap. 12 · Etaj 3"), the picked one with several,
        // after the wordmark's yellow dot.
        title: Row(children: [
          const WordmarkDot(),
          const SizedBox(width: 10),
          Flexible(child: Text(home.unit(scope.unit?.id)?.title ?? home.title ?? l10n.appTitle)),
        ]),
        actions: const [DemoChip(), SizedBox(width: 8)],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            ref.read(incidentControllerProvider.notifier).refresh(),
            ref.read(summaryProvider.notifier).refresh(),
          ]);
        },
        child: CustomScrollView(
          slivers: [
            if (scope.hasPicker) UnitScopeHeader(scope: scope),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  const RealAlarmBanner(),
                  HomeStatusBanner(
                    status: status,
                    connected: state.connected,
                    where: status.incident == null ? null : whereOf(status.incident!),
                    zoneLabel: prettyZone(labels, status.incident?.primaryZoneId),
                    onOpenAlarm: status.incident == null ? null : () => _openAlarm(context, status.incident!.id),
                  ),
                  // Only when calm, and only while no emergency profile exists.
                  if (status.kind == BuildingStatusKind.clear) ...[
                    const SizedBox(height: 12),
                    const CareHintCard(),
                  ],
                  const SizedBox(height: 20),
                  FoldHeader(
                    title: l10n.myRooms,
                    expanded: roomsOpen,
                    onToggle: () => foldCtl.toggleSection(roomsSection),
                    action: TextButton(
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const HomeSensorsScreen())),
                      child: Text(l10n.allSensors),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: !roomsOpen
                        ? const SizedBox(width: double.infinity)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 4),
                              if (rooms.isEmpty)
                                const _NoRooms()
                              else
                                RoomTileGrid(
                                  rooms: rooms,
                                  open: fold.openRooms,
                                  onToggle: (r) => foldCtl.toggleRoom(r.room.zoneId),
                                  onOpen: (r) => Navigator.of(context).push(MaterialPageRoute<void>(
                                    builder: (_) =>
                                        RoomScreen(zoneId: r.room.zoneId, title: r.room.label, sheetLabel: r.sheetLabel),
                                  )),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  FoldHeader(
                    title: l10n.buildingSection,
                    expanded: buildingOpen,
                    onToggle: () => foldCtl.toggleSection(buildingSection),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: !buildingOpen
                        ? const SizedBox(width: double.infinity)
                        : _BuildingStrip(
                            incidents: open,
                            whereOf: (i) => l10n.hazardWhereText(whereOf(i)),
                            onOpen: (i) => _openAlarm(context, i.id),
                          ),
                  ),
                  if (state.pending > 0) ...[
                    const SizedBox(height: 12),
                    _PendingRow(pending: state.pending),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// While the hub's summary loads, can't be fetched, or lists no sensors.
class _NoRooms extends ConsumerWidget {
  const _NoRooms();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final palette = context.palette;
    final state = ref.watch(summaryProvider);
    final (icon, text) = state.summary == null
        ? state.error == null
            ? (Icons.hourglass_empty, l10n.loadingSensorStatus)
            : (Icons.cloud_off, l10n.hubUnreachable)
        : (Icons.sensors_off, l10n.noSensorsConnected);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: palette.muted),
        title: Text(text),
      ),
    );
  }
}

/// "Niciun incident activ" on one panel row, or a row per open incident: the
/// hazard's sign, where it is for the resident, its state. An alarming one
/// opens the alarm.
class _BuildingStrip extends StatelessWidget {
  const _BuildingStrip({required this.incidents, required this.whereOf, required this.onOpen});
  final List<Incident> incidents;
  final String Function(Incident incident) whereOf;
  final void Function(Incident incident) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    if (incidents.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            const StateMark(color: HazardColors.normal, size: 9),
            const SizedBox(width: 10),
            Expanded(child: Text(l10n.noActiveIncidents, style: text.bodyMedium!.copyWith(color: palette.textSecondary))),
          ]),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, inc) in incidents.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: SafetySignImage(hazardSign(inc.hazardType), size: 32),
              title: Text(l10n.buildingIncident(l10n.hazardName(inc.hazardType))),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(whereOf(inc)), ClassificationText(incident: inc)],
              ),
              trailing: StatusPill(state: inc.state),
              onTap: inc.isAlarming ? () => onOpen(inc) : null,
            ),
          ),
        ],
      ],
    );
  }
}

/// Check-ins waiting to be sent (offline queue).
class _PendingRow extends StatelessWidget {
  const _PendingRow({required this.pending});
  final int pending;

  @override
  Widget build(BuildContext context) {
    final warn = context.palette.ink(HazardColors.warning);
    return Row(children: [
      Icon(Icons.cloud_upload_outlined, size: 18, color: warn),
      const SizedBox(width: 6),
      Expanded(child: Text(context.l10n.checkInsQueued(pending), style: TextStyle(color: warn))),
    ]);
  }
}
