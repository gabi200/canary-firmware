import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../logic/escape_plan.dart';
import '../../logic/floor_plan.dart';
import '../../logic/node_commands.dart';
import '../../logic/relative_location.dart';
import '../../logic/sensor_series.dart';
import '../../models/evacuation.dart';
import '../../models/incident.dart';
import '../../models/summary.dart';
import '../../models/zone_info.dart';
import '../../state/dashboard_providers.dart';
import '../../state/history_providers.dart';
import '../../state/providers.dart';
import '../../theme.dart';
import 'safety_sign.dart';
import 'sensor_tiles.dart';
import 'status_pill.dart';

/// "Schiță": the resident's rooms (own unit + common areas) as equal cells
/// placed by their relative position — not to scale. Each room shows its name,
/// status (color + word), temperature ≈, air / water icons and a dot per
/// sensor; common areas are dashed. A room hit by an open incident turns red
/// (pulsing unless reduced motion) with the hazard sign and "Evită". Tapping a
/// room lists its sensors.
class FloorPlanSketch extends ConsumerWidget {
  const FloorPlanSketch({super.key, required this.summary, required this.onOpenNode, this.labelOf});
  final BuildingSummary summary;
  final void Function(NodeAnalysis node, String zoneLabel) onOpenNode;

  /// A room's name; defaults to its label ("Bucătărie · Ap. 12" where flats mix).
  final String Function(ZoneSummary zone)? labelOf;

  String _nameOf(ZoneSummary z) => labelOf?.call(z) ?? _label(z);

  static const _gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final infos = {for (final z in ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[]) z.id: z};
    final zones = summary.zones;
    final incidents = ref.watch(incidentControllerProvider).incidents.where((i) => !i.isClosed).toList();

    final positioned = [
      for (final z in zones)
        if (infos[z.zoneId]?.hasPosition ?? false) (id: z.zoneId, x: infos[z.zoneId]!.posX!, y: infos[z.zoneId]!.posY!),
    ];
    final cells = {...gridLayout(positioned)};
    var cols = cells.isEmpty ? 0 : cells.values.map((c) => c.col).reduce(math.max) + 1;
    var rows = cells.isEmpty ? 0 : cells.values.map((c) => c.row).reduce(math.max) + 1;
    // Rooms without a position follow below, in summary order.
    final unplaced = [
      for (final z in zones)
        if (!cells.containsKey(z.zoneId)) z.zoneId
    ];
    if (unplaced.isNotEmpty) {
      cols = math.max(cols, math.min(3, unplaced.length));
      for (var i = 0; i < unplaced.length; i++) {
        cells[unplaced[i]] = (col: i % cols, row: rows + i ~/ cols);
      }
      rows += (unplaced.length / cols).ceil();
    }

    return LayoutBuilder(builder: (context, constraints) {
      final minCell = MediaQuery.textScalerOf(context).scale(112);
      final cellW = math.max(minCell, (constraints.maxWidth - _gap * (cols - 1)) / math.max(cols, 1));
      final width = cellW * cols + _gap * (cols - 1);
      final grid = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var r = 0; r < rows; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r < rows - 1 ? _gap : 0),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var c = 0; c < cols; c++) ...[
                      if (c > 0) const SizedBox(width: _gap),
                      SizedBox(
                        width: cellW,
                        child: () {
                          final id = cells.entries.where((e) => e.value == (col: c, row: r)).firstOrNull?.key;
                          final zone = id == null ? null : zones.firstWhere((z) => z.zoneId == id);
                          if (zone == null) return const SizedBox.shrink();
                          final info = infos[zone.zoneId];
                          final hit = incidents.where((i) => i.hazardZoneIds.contains(zone.zoneId)).firstOrNull;
                          return _RoomCell(
                            zone: zone,
                            label: _nameOf(zone),
                            common: info?.isCommon ?? false,
                            incident: hit,
                            onTap: () => _showRoom(context, zone),
                          );
                        }(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(positioned.isEmpty && zones.isNotEmpty ? l10n.sketchNoPositions : l10n.sketchHint,
            style: TextStyle(fontSize: 13, color: context.palette.muted)),
        const SizedBox(height: 8),
        if (width > constraints.maxWidth + 0.5)
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: width, child: grid))
        else
          grid,
      ]);
    });
  }

  void _showRoom(BuildContext context, ZoneSummary zone) {
    final label = _nameOf(zone);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text(label, style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final n in zone.nodes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(n.kind == 'water' ? Icons.water_damage : Icons.air),
                title: Text(n.name),
                subtitle: Text(n.headline.isNotEmpty ? n.headline : sheet.l10n.analysisStatus(n.status)),
                trailing: StatusPill(
                  state: n.online ? (n.stale ? 'stale' : n.status) : 'offline',
                  color: n.isLive ? HazardColors.forLevel(n.status) : HazardColors.unknown,
                ),
                onTap: () {
                  Navigator.of(sheet).pop();
                  onOpenNode(n, label);
                },
              ),
          ],
        ),
      ),
    );
  }
}

String _label(ZoneSummary z) => z.zoneLabel.isNotEmpty ? z.zoneLabel : prettyZone(null, z.zoneId);

class _RoomCell extends ConsumerStatefulWidget {
  const _RoomCell(
      {required this.zone, required this.label, required this.common, required this.incident, required this.onTap});
  final ZoneSummary zone;
  final String label;
  final bool common;
  final Incident? incident;
  final VoidCallback onTap;

  @override
  ConsumerState<_RoomCell> createState() => _RoomCellState();
}

class _RoomCellState extends ConsumerState<_RoomCell> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final zone = widget.zone;
    final incident = widget.incident;
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (incident != null && !reduceMotion) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating) {
      _pulse.stop();
    }

    final status = incident != null ? 'danger' : zone.status;
    final palette = context.palette;
    final base = HazardColors.forLevel(status);
    final color = palette.ink(base);
    final word = incident != null ? l10n.hazardName(incident.hazardType) : l10n.analysisStatus(zone.status);
    NodeAnalysis? air;
    NodeAnalysis? water;
    for (final n in zone.nodes) {
      if (n.kind == 'air') air ??= n;
      if (n.kind == 'water') water ??= n;
    }
    final airNode = air;
    final climate =
        airNode != null && airNode.isLive ? ref.watch(latestClimateProvider(airNode.nodeId)).valueOrNull : null;
    final temp = climate == null ? null : Series.of(climate, HistoryFields.temperature).latest;
    final airTone = airNode == null ? null : airChipState(airNode)?.tone;
    final leak = water?.indicator('leak');
    final waterTone = leak == null ? null : toneForLevel(leak.level);
    final label = widget.label;
    final lastCommand = latestCommand(zone.nodes);
    final lastTest = l10n.lastTestText(lastCommand);

    final semantics = [
      label,
      if (widget.common) l10n.sketchCommonArea,
      word,
      if (temp != null) l10n.spokenTemperature(l10n.decimal(temp)),
      lastTest,
      l10n.sensorCount(zone.nodes.length),
      if (incident != null) l10n.sketchAvoid,
    ].join(', ');

    Widget cell(double t) {
      final bg = incident != null
          ? Color.lerp(HazardColors.alarm.withAlpha(40), HazardColors.alarm.withAlpha(110), t)!
          : palette.tint(base, widget.common ? 14 : 26);
      final content = Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            if (widget.common)
              Text(l10n.sketchCommonArea,
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: context.palette.muted)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(incident != null ? Icons.warning_rounded : toneIcon(toneForLevel(zone.status)),
                  size: 16, color: color),
              const SizedBox(width: 4),
              Flexible(
                child:
                    Text(word, maxLines: 2, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
              ),
            ]),
            if (incident != null) ...[
              const SizedBox(height: 6),
              Row(children: [
                SafetySignImage(hazardSign(incident.hazardType), size: 28),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(l10n.sketchAvoid,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: HazardColors.alarm)),
                ),
              ]),
            ],
            const SizedBox(height: 4),
            Text(l10n.lastTestText(lastCommand, short: true),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.palette.muted)),
            const Spacer(),
            if (temp != null)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('≈ ${l10n.decimal(temp)} °C',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: context.palette.text)),
              ),
            const SizedBox(height: 4),
            Row(children: [
              if (airNode != null) Icon(Icons.air, size: 18, color: palette.ink(toneColor(airTone))),
              if (water != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.water_drop_outlined, size: 18, color: palette.ink(toneColor(waterTone))),
              ],
              const Spacer(),
              for (final n in zone.nodes)
                Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: Icon(Icons.circle,
                      size: 9, color: palette.ink(n.isLive ? HazardColors.forLevel(n.status) : HazardColors.unknown)),
                ),
            ]),
          ],
        ),
      );
      return CustomPaint(
        foregroundPainter: widget.common ? _DashedBorder(color: color.withAlpha(200)) : null,
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: widget.common ? BorderSide.none : BorderSide(color: color, width: incident != null ? 3 : 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
              onTap: widget.onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 120),
                child: content,
              )),
        ),
      );
    }

    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: incident != null && !reduceMotion
          ? AnimatedBuilder(animation: _pulse, builder: (_, __) => cell(_pulse.value))
          : cell(0),
    );
  }
}

/// The alarm screen's small floor plan (see [escapePlan]): the resident's own
/// apartment with its rooms and a "Tu" mark, every other apartment as one block
/// with its name, the common areas on the way out, and the exit. Red only for
/// the danger (the block it is in and the room itself); green arrows lead from
/// home to the exit. Under it a short legend and the affected rooms in words
/// (the plan itself is hidden from screen readers; the list says it all).
class IncidentPlan extends StatelessWidget {
  const IncidentPlan({super.key, required this.incident, required this.zones, required this.home, this.route});
  final Incident incident;

  /// The building's zones (`GET /zones`).
  final List<ZoneInfo> zones;
  final ResidentHome home;

  /// The way out shown under the plan, drawn on it from home to the exit.
  final EvacuationRoute? route;

  static const _gapX = 8.0;
  static const _gapY = 16.0; // room for the way-out arrows between rows

  /// Columns (rows) holding a drawn room or a one-cell block get a full cell;
  /// the rest only belong to name-only apartments and get less.
  static List<double> _weights(EscapePlan plan, {required bool cols}) {
    final detail = <int>{};
    for (final b in plan.blocks) {
      if (b.kind == PlanBlockKind.common || b.kind == PlanBlockKind.exit) detail.add(cols ? b.area.col : b.area.row);
      for (final r in b.rooms) {
        detail.add(cols ? r.cell.col : r.cell.row);
      }
    }
    return [for (var i = 0; i < (cols ? plan.cols : plan.rows); i++) detail.contains(i) ? 1.0 : (cols ? 0.5 : 0.6)];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final plan = escapePlan(incident: incident, zones: zones, home: home, route: route);
    final affected = affectedRooms(incident, {for (final z in zones) z.id: z}, home);
    if (plan.isEmpty && affected.isEmpty) return const SizedBox.shrink();

    String roomName(ZoneInfo z) => z.isCommon || z.unitLabel == null ? z.label : '${z.label} · ${z.unitLabel}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!plan.isEmpty) ...[
          Text(plan.floorLabel == null ? l10n.planCaptionNoFloor : l10n.planCaption(plan.floorLabel!),
              style: TextStyle(fontSize: 13, color: palette.muted)),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: LayoutBuilder(builder: (context, constraints) {
              final scaler = MediaQuery.textScalerOf(context);
              final wx = _weights(plan, cols: true);
              final wy = _weights(plan, cols: false);
              final unitW = math.max(scaler.scale(52),
                  (constraints.maxWidth - _gapX * (plan.cols - 1)) / wx.fold<double>(0, (a, b) => a + b));
              final unitH = scaler.scale(56);
              // Left / top edge of each column / row, and one past the last.
              final xs = [0.0];
              for (final w in wx) {
                xs.add(xs.last + w * unitW + _gapX);
              }
              final ys = [0.0];
              for (final w in wy) {
                ys.add(ys.last + w * unitH + _gapY);
              }
              Rect span(int col, int row, int cols, int rows) =>
                  Rect.fromLTRB(xs[col], ys[row], xs[col + cols] - _gapX, ys[row + rows] - _gapY);
              Rect rectOf(PlanArea a) => span(a.col, a.row, a.cols, a.rows);
              final width = xs.last - _gapX;
              final height = ys.last - _gapY;
              final homes = plan.blocks.where((b) => b.kind == PlanBlockKind.home).length;
              final canvas = SizedBox(
                width: width,
                height: height,
                child: Stack(
                  children: [
                    for (final b in plan.blocks)
                      Positioned.fromRect(
                        rect: rectOf(b.area),
                        child: _PlanBlockView(
                          block: b,
                          hazardType: incident.hazardType,
                          // A cell of the block, relative to its top-left corner.
                          cellRect: (c) => span(c.col, c.row, 1, 1).shift(-rectOf(b.area).topLeft),
                          // Several homes: each also says which flat it is.
                          showHomeName: homes > 1,
                        ),
                      ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _WayOutPainter(
                            rects: [for (final id in plan.path) rectOf(plan.block(id)!.area)],
                            color: palette.ink(HazardColors.normal),
                            outline: palette.surface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
              return width > constraints.maxWidth + 0.5
                  ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: canvas)
                  : canvas;
            }),
          ),
          const SizedBox(height: 10),
          ExcludeSemantics(
            child: Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                if (plan.blocks.any((b) => b.kind == PlanBlockKind.home))
                  _LegendItem(
                      icon: Icon(Icons.person_pin_circle, size: 20, color: palette.ink(HazardColors.info)),
                      label: l10n.planYou),
                _LegendItem(icon: const _Swatch(color: HazardColors.alarm), label: l10n.planDanger),
                if (plan.path.contains('exit'))
                  _LegendItem(icon: const _Swatch(color: HazardColors.normal), label: l10n.planExit),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(l10n.affectedRoomsTitle,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: palette.text)),
        const SizedBox(height: 4),
        for (final a in affected)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(a.source ? Icons.warning_rounded : Icons.error_outline,
                    size: 20, color: palette.ink(HazardColors.alarm)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      roomName(a.zone),
                      if (a.source || a.mine)
                        '(${[if (a.source) l10n.roomTagSource, if (a.mine) l10n.roomTagYours].join(', ')})',
                    ].join(' '),
                    style: TextStyle(fontSize: 16, fontWeight: a.source ? FontWeight.w700 : null, color: palette.text),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One block of the plan, with the rooms it shows at their own cells.
class _PlanBlockView extends StatelessWidget {
  const _PlanBlockView(
      {required this.block, required this.hazardType, required this.cellRect, required this.showHomeName});
  final PlanBlock block;
  final String hazardType;

  /// Where a cell of the block is, relative to the block.
  final Rect Function(GridCell cell) cellRect;

  /// A home also shows its flat's name (the resident has several).
  final bool showHomeName;

  Rect _cell(GridCell c) => cellRect(c);

  /// The block's cells without a room, for its name or the "Tu" mark.
  List<GridCell> _freeCells() => [
        for (var r = block.area.row; r < block.area.row + block.area.rows; r++)
          for (var c = block.area.col; c < block.area.col + block.area.cols; c++)
            if (!block.rooms.any((room) => room.cell == (col: c, row: r))) (col: c, row: r),
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final red = palette.ink(HazardColors.alarm);
    Widget label(String text, {Color? color, double size = 16}) => Center(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: color ?? palette.text)),
            ),
          ),
        );

    switch (block.kind) {
      case PlanBlockKind.exit:
        return Container(
          decoration: BoxDecoration(color: HazardColors.normal, borderRadius: BorderRadius.circular(10)),
          // Clear of the arrow coming in from above.
          padding: const EdgeInsets.only(top: 9),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SafetySignImage(SafetySign.e002, size: 22, decorative: true),
              Flexible(child: label(l10n.planExit, color: HazardColors.onHazard, size: 14)),
            ],
          ),
        );
      case PlanBlockKind.common:
        if (block.danger) {
          return Container(
            decoration: BoxDecoration(color: HazardColors.alarm, borderRadius: BorderRadius.circular(10)),
            child: label(block.label, color: HazardColors.onHazard, size: 14),
          );
        }
        final cell = Container(
          decoration: BoxDecoration(
            color: palette.tile,
            borderRadius: BorderRadius.circular(10),
            border: block.onRoute ? Border.all(color: palette.ink(HazardColors.normal), width: 2) : null,
          ),
          child: label(block.label, color: palette.muted, size: 13),
        );
        return block.onRoute
            ? cell
            : CustomPaint(foregroundPainter: _DashedBorder(color: palette.faint, radius: 10), child: cell);
      case PlanBlockKind.home:
      case PlanBlockKind.apartment:
        final home = block.kind == PlanBlockKind.home;
        final freeCells = _freeCells();
        final free = freeCells.firstOrNull;
        return Container(
          decoration: BoxDecoration(
            color: home ? palette.tint(HazardColors.info, 26) : palette.tile,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: block.danger ? red : (home ? palette.ink(HazardColors.info) : palette.tileBorder),
              width: block.danger ? 3 : (home ? 2 : 1.5),
            ),
          ),
          child: Stack(
            children: [
              // The name (the "Tu" mark at home) where no room is drawn.
              if (home && free != null)
                Positioned.fromRect(
                  rect: _cell(free),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_pin_circle, size: 22, color: palette.ink(HazardColors.info)),
                        Flexible(child: label(l10n.planYou, color: palette.ink(HazardColors.info), size: 16)),
                      ],
                    ),
                  ),
                ),
              if (home && showHomeName && freeCells.length > 1)
                Positioned.fromRect(
                  rect: _cell(freeCells.last),
                  child: label(block.label, color: palette.ink(HazardColors.info), size: 15),
                )
              else if (!home)
                block.rooms.isEmpty || free == null
                    ? Positioned.fill(child: label(block.label, color: palette.muted))
                    : Positioned.fromRect(rect: _cell(free), child: label(block.label, color: palette.muted)),
              for (final room in block.rooms)
                Positioned.fromRect(
                  rect: _cell(room.cell).deflate(3),
                  child: Container(
                    decoration: BoxDecoration(
                      color: room.danger ? HazardColors.alarm : palette.surface,
                      borderRadius: BorderRadius.circular(7),
                      border: room.danger ? null : Border.all(color: palette.tileBorder),
                    ),
                    child: room.danger
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SafetySignImage(hazardSign(hazardType), size: 18, decorative: true),
                              Flexible(child: label(room.label, color: HazardColors.onHazard, size: 14)),
                            ],
                          )
                        : label(room.label, size: 14),
                  ),
                ),
            ],
          ),
        );
    }
  }
}

/// Green arrows across the edges between the blocks of the way out (home,
/// hallway, ..., exit), pointing towards the exit; never over a block's middle.
class _WayOutPainter extends CustomPainter {
  _WayOutPainter({required this.rects, required this.color, required this.outline});
  final List<Rect> rects;
  final Color color;

  /// A halo so the arrow reads on any block colour.
  final Color outline;

  /// Where the segment from [a]'s centre to [b]'s centre leaves rect [a].
  static Offset _exitPoint(Rect a, Offset to) {
    final c = a.center;
    final d = to - c;
    final tx = d.dx == 0 ? double.infinity : (a.width / 2) / d.dx.abs();
    final ty = d.dy == 0 ? double.infinity : (a.height / 2) / d.dy.abs();
    return c + d * math.min(1, math.min(tx, ty));
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i + 1 < rects.length; i++) {
      final a = rects[i];
      final b = rects[i + 1];
      final from = _exitPoint(a, b.center);
      final to = _exitPoint(b, a.center);
      final mid = Offset.lerp(from, to, 0.5)!;
      final dist = (b.center - a.center).distance;
      if (dist == 0) continue;
      final dir = (b.center - a.center) / dist;
      final start = mid - dir * 11;
      final end = mid + dir * 9;
      final normal = Offset(-dir.dy, dir.dx);
      final head = Path()
        ..moveTo(end.dx + dir.dx * 5, end.dy + dir.dy * 5)
        ..lineTo(end.dx - dir.dx * 5 + normal.dx * 8, end.dy - dir.dy * 5 + normal.dy * 8)
        ..lineTo(end.dx - dir.dx * 5 - normal.dx * 8, end.dy - dir.dy * 5 - normal.dy * 8)
        ..close();
      for (final (paint, grow) in [(outline, 3.0), (color, 0.0)]) {
        canvas.drawLine(
            start,
            end - dir * 4,
            Paint()
              ..color = paint
              ..strokeWidth = 6 + grow * 2
              ..strokeCap = StrokeCap.round);
        canvas.drawPath(
            head,
            Paint()
              ..color = paint
              ..style = PaintingStyle.fill);
        if (grow > 0) {
          canvas.drawPath(
              head,
              Paint()
                ..color = paint
                ..style = PaintingStyle.stroke
                ..strokeWidth = grow * 2
                ..strokeJoin = StrokeJoin.round);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_WayOutPainter old) =>
      !listEquals(old.rects, rects) || old.color != color || old.outline != outline;
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 18, height: 18, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)));
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.icon, required this.label});
  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: context.palette.text)),
        ),
      ],
    );
  }
}

/// Dashed rounded outline for common areas.
class _DashedBorder extends CustomPainter {
  _DashedBorder({required this.color, this.radius = 14});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(1));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 6, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color || old.radius != radius;
}
