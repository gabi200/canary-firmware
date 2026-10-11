import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../logic/sensor_series.dart';
import '../../logic/unit_scope.dart';
import '../../models/incident.dart';
import '../../state/history_providers.dart';
import '../../theme.dart';
import 'home_status_section.dart';

/// A room on the resident's home: its sensors and name, the kind of room, and
/// the open incident that reached it, if any.
typedef RoomTileData = ({ScopeRoom room, String sheetLabel, String? kind, bool common, Incident? incident});

/// Material icon for a room kind from the hub's zone list.
IconData roomKindIcon(String? kind) => switch (kind) {
      'kitchen' => Icons.kitchen,
      'bathroom' => Icons.bathtub,
      'bedroom' => Icons.bed,
      'living_room' => Icons.weekend,
      'hallway' => Icons.door_front_door,
      'stairwell' => Icons.stairs,
      'boiler' => Icons.hvac,
      _ => Icons.meeting_room,
    };

/// Home rooms before common areas, then kitchen, bathroom, bedroom, living
/// room, hallway, stairwell, boiler room, the rest; then by name.
int compareRoomTiles(RoomTileData a, RoomTileData b) {
  const order = ['kitchen', 'bathroom', 'bedroom', 'living_room', 'hallway', 'stairwell', 'boiler'];
  int rank(String? kind) => kind == null || !order.contains(kind) ? order.length : order.indexOf(kind);
  if (a.common != b.common) return a.common ? 1 : -1;
  final byKind = rank(a.kind).compareTo(rank(b.kind));
  return byKind != 0 ? byKind : compareNatural(a.room.label, b.room.label);
}

/// A room's status for its dot: the worst of its live sensors; "unknown" when
/// none is reporting; danger while an incident is in it.
String roomTileStatus(RoomTileData r) {
  if (r.incident != null) return 'danger';
  return worstStatus(r.room.nodes.where((n) => n.isLive).map((n) => n.status));
}

/// The resident's rooms as small tiles, three to a row (two at large text):
/// the kind of room, its name, a status dot and the temperature ≈. Tapping a
/// tile opens the room ([onOpen]); its chevron shows the room's sensors inline
/// under the tile's row ([open] ids, toggled with [onToggle]).
class RoomTileGrid extends StatelessWidget {
  const RoomTileGrid({
    super.key,
    required this.rooms,
    required this.open,
    required this.onOpen,
    required this.onToggle,
  });
  final List<RoomTileData> rooms;
  final Set<String> open;
  final void Function(RoomTileData room) onOpen;
  final void Function(RoomTileData room) onToggle;

  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final minTile = MediaQuery.textScalerOf(context).scale(104);
      final cols = math.max(1, math.min(3, ((constraints.maxWidth + _gap) / (minTile + _gap)).floor()));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rooms.length; i += cols) ...[
            if (i > 0) const SizedBox(height: _gap),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = i; j < i + cols; j++) ...[
                    if (j > i) const SizedBox(width: _gap),
                    Expanded(
                      child: j < rooms.length
                          ? _RoomTile(
                              data: rooms[j],
                              open: open.contains(rooms[j].room.zoneId),
                              onOpen: () => onOpen(rooms[j]),
                              onToggle: () => onToggle(rooms[j]),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
            // The row's rooms opened inline, full width under it.
            for (var j = i; j < i + cols && j < rooms.length; j++)
              AnimatedSize(
                key: ValueKey('inline-${rooms[j].room.zoneId}'),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: open.contains(rooms[j].room.zoneId)
                    ? Padding(
                        padding: const EdgeInsets.only(top: _gap),
                        child: RoomCard(
                          zone: rooms[j].room.zone,
                          label: rooms[j].room.label,
                          sheetLabel: rooms[j].sheetLabel,
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
          ],
        ],
      );
    });
  }
}

class _RoomTile extends ConsumerWidget {
  const _RoomTile({required this.data, required this.open, required this.onOpen, required this.onToggle});
  final RoomTileData data;
  final bool open;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final palette = context.palette;
    final room = data.room;
    final incident = data.incident;
    final status = roomTileStatus(data);
    final statusColor = palette.ink(HazardColors.forLevel(status));
    final flagged = status == 'attention' || status == 'danger';
    final air = room.nodes.where((n) => n.kind == 'air' && n.isLive).firstOrNull;
    final climate = air == null ? null : ref.watch(latestClimateProvider(air.nodeId)).valueOrNull;
    final temp = climate == null ? null : Series.of(climate, HistoryFields.temperature).latest;
    final tempText = temp == null ? null : l10n.decimal(temp, digits: 0);
    final offline = room.nodes.isNotEmpty && !room.nodes.any((n) => n.isLive);
    final word = incident != null ? l10n.hazardName(incident.hazardType) : l10n.analysisStatus(status);

    final semantics = [
      room.label,
      if (data.common) l10n.sketchCommonArea,
      word,
      if (offline) l10n.sensorOffline,
      if (tempText != null) l10n.spokenTemperature(tempText),
    ].join(', ');

    return Material(
      color: incident != null ? palette.tint(HazardColors.alarm, 46) : palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: incident != null ? palette.ink(HazardColors.alarm) : palette.tileBorder,
          width: incident != null ? 2.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InkWell(
            onTap: onOpen,
            child: Semantics(
              button: true,
              label: semantics,
              hint: l10n.openRoom,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(roomKindIcon(data.kind), size: 28, color: incident != null ? statusColor : palette.muted),
                        const Spacer(),
                        // A dot, with "!" when something needs a look (not by colour alone).
                        Icon(flagged ? Icons.error : Icons.circle, size: flagged ? 22 : 14, color: statusColor),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(room.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: palette.text)),
                    if (data.common)
                      Text(l10n.sketchCommonArea,
                          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: palette.muted)),
                    if (incident != null)
                      Text(word, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: statusColor)),
                    if (offline) Text(l10n.sensorOffline, style: TextStyle(fontSize: 13, color: palette.muted)),
                    const Spacer(),
                    const SizedBox(height: 6),
                    // Room for the chevron at the bottom right.
                    Padding(
                      padding: const EdgeInsets.only(right: 40),
                      child: SizedBox(
                        height: 28,
                        child: tempText == null
                            ? null
                            : FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text('≈ $tempText °C',
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: palette.text)),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onToggle,
              tooltip: open ? l10n.hideSensors : l10n.showSensors,
              icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 28, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A home section's title with a chevron that folds the section away.
class FoldHeader extends StatelessWidget {
  const FoldHeader({super.key, required this.title, required this.expanded, required this.onToggle});
  final String title;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return Semantics(
      button: true,
      expanded: expanded,
      label: title,
      hint: expanded ? l10n.collapseSection : l10n.expandSection,
      excludeSemantics: true,
      onTap: onToggle,
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 28, color: palette.muted),
            ],
          ),
        ),
      ),
    );
  }
}
