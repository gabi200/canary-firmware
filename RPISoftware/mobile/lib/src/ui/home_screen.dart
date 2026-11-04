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
import 'settings_screen.dart';
import 'widgets/care_hint_card.dart';
import 'widgets/home_banner.dart';
import 'widgets/mode_strip.dart';
import 'widgets/room_tiles.dart';
import 'widgets/safety_sign.dart';
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
        // The resident's home ("Ap. 12 · Etaj 3"), the picked one with several.
        title: Text(home.unit(scope.unit?.id)?.title ?? home.title ?? l10n.appTitle),
        actions: [
          const DemoChip(),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l10n.settings,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
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
                    where: status.incident == null ? null : whereOf(status.incident!),
                    zoneLabel: prettyZone(labels, status.incident?.primaryZoneId),
                    onOpenAlarm: status.incident == null ? null : () => _openAlarm(context, status.incident!.id),
                  ),
                  // Only when calm, and only while no emergency profile exists.
                  if (status.kind == BuildingStatusKind.clear) ...[
                    const SizedBox(height: 12),
                    const CareHintCard(),
                  ],
                  const SizedBox(height: 16),
                  FoldHeader(
                    title: l10n.myRooms,
                    expanded: roomsOpen,
                    onToggle: () => foldCtl.toggleSection(roomsSection),
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
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                                  icon: const Icon(Icons.sensors),
                                  label: Text(l10n.allSensors),
                                  onPressed: () => Navigator.of(context)
                                      .push(MaterialPageRoute<void>(builder: (_) => const HomeSensorsScreen())),
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 12),
                  _ConnectivityRow(connected: state.connected, pending: state.pending),
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

/// "Clădirea: niciun incident activ", or a line per open incident: the hazard,
/// where it is for the resident, its state. An alarming one opens the alarm.
class _BuildingStrip extends StatelessWidget {
  const _BuildingStrip({required this.incidents, required this.whereOf, required this.onOpen});
  final List<Incident> incidents;
  final String Function(Incident incident) whereOf;
  final void Function(Incident incident) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    if (incidents.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(top: 4),
        child: ListTile(
          leading: Icon(Icons.apartment, color: palette.ink(HazardColors.normal)),
          title: Text(l10n.buildingNoIncidents),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final inc in incidents)
          Card(
            margin: const EdgeInsets.only(top: 4),
            child: ListTile(
              leading: SafetySignImage(hazardSign(inc.hazardType), size: 36),
              title: Text(l10n.buildingIncident(l10n.hazardName(inc.hazardType))),
              subtitle: Text(whereOf(inc)),
              trailing: StatusPill(state: inc.state),
              onTap: inc.isAlarming ? () => onOpen(inc) : null,
            ),
          ),
      ],
    );
  }
}

class _ConnectivityRow extends StatelessWidget {
  const _ConnectivityRow({required this.connected, required this.pending});
  final bool connected;
  final int pending;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final warn = palette.ink(HazardColors.warning);
    return Row(
      children: [
        Icon(connected ? Icons.wifi : Icons.wifi_off,
            size: 18, color: connected ? palette.ink(HazardColors.normal) : palette.faint),
        const SizedBox(width: 6),
        Text(connected ? l10n.live : l10n.reconnecting, style: TextStyle(color: palette.muted)),
        const Spacer(),
        if (pending > 0)
          Row(children: [
            Icon(Icons.cloud_upload, size: 18, color: warn),
            const SizedBox(width: 6),
            Text(l10n.checkInsQueued(pending), style: TextStyle(color: warn)),
          ]),
      ],
    );
  }
}
