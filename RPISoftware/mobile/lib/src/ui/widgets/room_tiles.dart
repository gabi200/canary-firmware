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
import 'status_hero.dart';

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

/// The resident's rooms as cards, two to a row on a phone (one at large text,
/// three on a tablet): the room's name, a state mark and one line (its state and
/// the temperature ≈). Tapping a
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
      final minTile = MediaQuery.textScalerOf(context).scale(150);
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
    final text = Theme.of(context).textTheme;
    final room = data.room;
    final incident = data.incident;
    final status = roomTileStatus(data);
    final solid = HazardColors.forLevel(status);
    final flagged = status == 'attention' || status == 'danger';
    final air = room.nodes.where((n) => n.kind == 'air' && n.isLive).firstOrNull;
    final climate = air == null ? null : ref.watch(latestClimateProvider(air.nodeId)).valueOrNull;
    final temp = climate == null ? null : Series.of(climate, HistoryFields.temperature).latest;
    final tempText = temp == null ? null : l10n.decimal(temp, digits: 0);
    final offline = room.nodes.isNotEmpty && !room.nodes.any((n) => n.isLive);
    final word = incident != null
        ? l10n.hazardName(incident.hazardType)
        : offline
            ? l10n.sensorOffline
            : l10n.analysisStatus(status);
    final line = [word, if (tempText != null && incident == null) '≈\u00A0$tempText\u00A0°C'].join('\u00A0·\u00A0');

    final semantics = [
      room.label,
      if (data.common) l10n.sketchCommonArea,
      word,
      if (tempText != null) l10n.spokenTemperature(tempText),
    ].join(', ');

    return Material(
      color: flagged ? palette.tint(solid) : palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CanaryRadius.container),
        side: BorderSide(color: flagged ? palette.stateBorder(solid) : palette.hairline, width: incident != null ? 1.5 : 1),
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
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(room.label, style: text.titleSmall!.copyWith(fontSize: 15, height: 1.3))),
                        const SizedBox(width: 8),
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: StateMark(color: offline && incident == null ? HazardColors.unknown : solid, size: 9),
                        ),
                      ],
                    ),
                    if (data.common)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(l10n.sketchCommonArea, style: text.labelMedium),
                      ),
                    const Spacer(),
                    const SizedBox(height: 10),
                    // Room for the chevron at the bottom right.
                    Padding(
                      padding: const EdgeInsets.only(right: 36),
                      child: Text(line,
                          style: text.bodySmall!.copyWith(
                            color: flagged ? palette.ink(solid) : palette.muted,
                            fontWeight: flagged ? FontWeight.w600 : FontWeight.w400,
                          )),
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
              icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 20, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A home section's title with an optional [action] link and a chevron that folds
/// the section away.
class FoldHeader extends StatelessWidget {
  const FoldHeader({super.key, required this.title, required this.expanded, required this.onToggle, this.action});
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              expanded: expanded,
              label: title,
              hint: expanded ? l10n.collapseSection : l10n.expandSection,
              excludeSemantics: true,
              onTap: onToggle,
              child: InkWell(
                onTap: onToggle,
                borderRadius: BorderRadius.circular(CanaryRadius.control),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      Flexible(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
                      const SizedBox(width: 4),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: palette.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (action != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.5),
              child: action!,
            ),
        ],
      ),
    );
  }
}
