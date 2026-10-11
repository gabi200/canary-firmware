import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../models/summary.dart';
import '../../state/dashboard_providers.dart';
import '../../state/history_providers.dart';
import '../../state/providers.dart';
import '../../state/scope_providers.dart';
import '../../theme.dart';
import '../sensor_chart_page.dart';
import 'floor_plan_sketch.dart';
import 'node_commands.dart';
import 'sensor_tiles.dart';
import 'status_pill.dart';

/// "Home status": the hub's analysis of the building's sensors — an overall
/// card, then one card per room with big "vital" chips (temperature ≈,
/// humidity ≈, air quality, leaks) and each sensor's headline. Tapping opens the
/// sensor sheet: measurement tiles with charts plus the full analysis.
/// Headlines, advice and indicator text come from the hub in the app language
/// (Accept-Language); the local strings here are fallbacks and chrome. With an
/// apartment picker (staff, or several homes) only the picked rooms show; the
/// screen pins the picker itself (UnitScopeHeader).
class HomeStatusSection extends ConsumerWidget {
  const HomeStatusSection({super.key, this.title});

  /// Section heading; defaults to "Home status".
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(summaryProvider);
    final summary = state.summary;
    final l10n = context.l10n;
    final view = ref.watch(homeViewProvider);
    final sketch = view == 'sketch' && summary != null && summary.hasNodes;
    final scope = ref.watch(summaryScopeProvider);
    String labelOf(ZoneSummary z) {
      final room = scope.roomOf(z.zoneId);
      return room != null ? scope.labelOf(room) : _plainLabel(z);
    }

    String sheetLabelOf(String? zoneId, String fallback) {
      final room = scope.roomOf(zoneId);
      return room != null ? scope.sheetLabelOf(room) : fallback;
    }

    // Residents' test buttons depend on which zones are theirs: keep the zone
    // list loaded while home is on screen so a sensor sheet opens complete.
    if (ref.watch(sessionProvider)?.isResident ?? false) ref.watch(zonesInfoProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title, and the List / Sketch switch (wraps under it on narrow screens).
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Text(title ?? l10n.homeStatus, style: Theme.of(context).textTheme.titleMedium),
            if (summary != null && summary.hasNodes)
              SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(
                      value: 'list', icon: const Icon(Icons.view_agenda_outlined), label: Text(l10n.homeViewList)),
                  ButtonSegment(value: 'sketch', icon: const Icon(Icons.grid_view), label: Text(l10n.homeViewSketch)),
                ],
                selected: {view},
                onSelectionChanged: (s) => ref.read(homeViewProvider.notifier).set(s.first),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (summary != null && state.error != null) _RefreshFailedNote(updatedAt: state.updatedAt),
        if (summary == null)
          state.error == null ? const _LoadingCard() : const _UnavailableCard()
        else if (!summary.hasNodes)
          const _NoSensorsCard()
        else ...[
          _OverallCard(summary: summary),
          if (sketch) ...[
            const SizedBox(height: 12),
            FloorPlanSketch(
              // A picked unit: only its rooms; otherwise the whole plan as before.
              summary: scope.unit == null ? summary : summary.withZones([for (final r in scope.shown) r.zone]),
              labelOf: labelOf,
              onOpenNode: (node, label) => openNodeSheet(context, node, sheetLabelOf(node.zoneId, label)),
            ),
          ] else
            for (final zone in scope.hasPicker ? [for (final r in scope.shown) r.zone] : summary.zones)
              if (zone.nodes.isNotEmpty) ...[
                const SizedBox(height: 12),
                RoomCard(zone: zone, label: labelOf(zone), sheetLabel: sheetLabelOf(zone.zoneId, labelOf(zone))),
              ],
        ],
      ],
    );
  }
}

class _OverallCard extends StatelessWidget {
  const _OverallCard({required this.summary});
  final BuildingSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final base = HazardColors.forLevel(summary.status);
    final color = context.palette.ink(base);
    final incidents = summary.activeIncidents;
    return Card(
      color: context.palette.tint(base, 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(_statusIcon(summary.status), color: color, size: 36),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.headline.isNotEmpty ? summary.headline : l10n.analysisStatus(summary.status),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      l10n.sensorsOnline(summary.nodesOnline, summary.nodesTotal),
                      if (incidents > 0) l10n.activeIncidentCount(incidents),
                    ].join(' · '),
                    style: TextStyle(color: context.palette.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _plainLabel(ZoneSummary z) => z.zoneLabel.isNotEmpty ? z.zoneLabel : prettyZone(null, z.zoneId);

/// One room: a status dot and its name, the big "vital" chips, then a row per
/// sensor (tap: the sensor sheet with charts and test buttons). Used by the
/// list here, the room page and the rooms opened inline on the resident home.
class RoomCard extends StatelessWidget {
  const RoomCard({super.key, required this.zone, required this.label, required this.sheetLabel, this.showLabel = true});
  final ZoneSummary zone;

  /// "Bucătărie", or "Bucătărie · Ap. 12" where rooms of several flats mix.
  final String label;

  /// The room's name in the sensor sheet.
  final String sheetLabel;

  /// False where the page already names the room: the dot gets the status word.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final occupied = zone.occupied;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
            child: Row(
              children: [
                Icon(Icons.circle, size: 12, color: context.palette.ink(HazardColors.forLevel(zone.status))),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(showLabel ? label : context.l10n.analysisStatus(zone.status),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (occupied != null)
                  StatusPill(
                    state: 'occupancy',
                    label: occupied ? context.l10n.occupied : context.l10n.empty,
                    color: occupied ? HazardColors.info : HazardColors.unknown,
                  ),
              ],
            ),
          ),
          RoomVitals(zone: zone, onOpen: (node) => openNodeSheet(context, node, sheetLabel)),
          for (var i = 0; i < zone.nodes.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            _NodeTile(node: zone.nodes[i], zoneLabel: sheetLabel),
          ],
        ],
      ),
    );
  }
}

void openNodeSheet(BuildContext context, NodeAnalysis node, String zoneLabel) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _NodeSheet(initial: node, zoneLabel: zoneLabel),
  );
}

/// One sensor on a room card: name, status and the hub's headline. The
/// indicator list lives in the sensor sheet to keep the card short.
class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node, required this.zoneLabel});
  final NodeAnalysis node;
  final String zoneLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => openNodeSheet(context, node, zoneLabel),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_kindIcon(node.kind), size: 20, color: context.palette.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _NodeStatusPill(node: node),
                Icon(Icons.chevron_right, color: context.palette.faint),
              ],
            ),
            const SizedBox(height: 6),
            if (!node.isLive) ...[_NotReporting(node: node), const SizedBox(height: 6)],
            Text(_headline(context, node), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            LastTestLine(command: node.lastCommand, fontSize: 12),
          ],
        ),
      ),
    );
  }
}

/// One sensor: the hub's headline and advice, then measurement tiles for the
/// chosen window (last hour / 24 h / 7 days), then the full analysis. Watches
/// the summary and the history (refreshed every 30 s) so it stays current.
class _NodeSheet extends ConsumerStatefulWidget {
  const _NodeSheet({required this.initial, required this.zoneLabel});
  final NodeAnalysis initial;
  final String zoneLabel;

  @override
  ConsumerState<_NodeSheet> createState() => _NodeSheetState();
}

class _NodeSheetState extends ConsumerState<_NodeSheet> {
  int _minutes = historyRanges.first;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final node = ref.watch(summaryProvider).summary?.node(widget.initial.nodeId) ?? widget.initial;
    final measured = node.kind == 'air' || node.kind == 'water';
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(
            children: [
              Icon(_kindIcon(node.kind), color: context.palette.muted),
              const SizedBox(width: 10),
              Expanded(child: Text(node.name, style: Theme.of(context).textTheme.titleLarge)),
              _NodeStatusPill(node: node),
            ],
          ),
          const SizedBox(height: 4),
          Text('${widget.zoneLabel} · ${l10n.sensorKind(node.kind)}', style: TextStyle(color: context.palette.muted)),
          const SizedBox(height: 12),
          if (!node.isLive) ...[_NotReporting(node: node), const SizedBox(height: 12)],
          Text(_headline(context, node), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          if (node.advice.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(l10n.whatToDo, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final a in node.advice)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(a)),
                  ],
                ),
              ),
          ],
          // Test buttons (hidden when this user can't command the sensor).
          NodeCommandPanel(node: node, topGap: 20, showWho: ref.watch(sessionProvider)?.role != 'resident'),
          if (measured) ...[
            const SizedBox(height: 20),
            Text(l10n.measurements, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (final m in historyRanges)
                    ButtonSegment(
                      value: m,
                      label: Text(l10n.windowShort(m), semanticsLabel: l10n.windowName(m)),
                      tooltip: l10n.windowName(m),
                    ),
                ],
                selected: {_minutes},
                onSelectionChanged: (s) => setState(() => _minutes = s.first),
              ),
            ),
            const SizedBox(height: 12),
            _History(node: node, minutes: _minutes),
            if (node.kind == 'air') ...[
              const SizedBox(height: 8),
              Text(l10n.approxNote, style: TextStyle(fontSize: 12, color: context.palette.muted)),
            ],
          ],
          if (node.indicators.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(l10n.analysisDetails, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _Indicators(node: node),
          ],
        ],
      ),
    );
  }
}

/// Measurement tiles for one window: skeleton while loading, an error line with
/// retry (above the last good tiles when a refresh fails), or an empty note.
class _History extends ConsumerWidget {
  const _History({required this.node, required this.minutes});
  final NodeAnalysis node;
  final int minutes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final key = (nodeId: node.nodeId, kind: node.kind, minutes: minutes);
    final async = ref.watch(nodeHistoryProvider(key));
    final history = async.valueOrNull;
    final error = async.hasError ? _HistoryError(onRetry: () => ref.invalidate(nodeHistoryProvider(key))) : null;
    if (history == null) {
      return error ?? TileSkeletonGrid(count: node.kind == 'water' ? 2 : 6);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[error, const SizedBox(height: 8)],
        if (history.points.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.palette.tile,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              const Icon(Icons.hourglass_empty, color: HazardColors.unknown),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.noReadings(l10n.inWindow(minutes)))),
            ]),
          )
        else
          TileGrid(
            // Tap a tile: full-screen chart for that measurement.
            tiles: node.kind == 'water'
                ? waterTiles(l10n, history, node, onOpenLeak: () => openSensorChart(context, node, 'leak', minutes))
                : airTiles(l10n, history, onOpen: (key) => openSensorChart(context, node, key, minutes)),
          ),
      ],
    );
  }
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        const Icon(Icons.sync_problem, color: HazardColors.warning),
        const SizedBox(width: 8),
        Expanded(child: Text(l10n.historyFailed)),
        TextButton(onPressed: onRetry, child: Text(l10n.retry)),
      ],
    );
  }
}

class _NodeStatusPill extends StatelessWidget {
  const _NodeStatusPill({required this.node});
  final NodeAnalysis node;

  @override
  Widget build(BuildContext context) {
    if (!node.online) return const StatusPill(state: 'offline', color: HazardColors.unknown);
    if (node.stale) return const StatusPill(state: 'stale', color: HazardColors.unknown);
    return StatusPill(state: node.status, color: HazardColors.forLevel(node.status));
  }
}

/// Offline / stale warning strip.
class _NotReporting extends StatelessWidget {
  const _NotReporting({required this.node});
  final NodeAnalysis node;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final what = node.online ? l10n.noRecentData : l10n.sensorOffline;
    final seen = node.lastSeenTs;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: HazardColors.warning.withAlpha(36),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(node.online ? Icons.hourglass_empty : Icons.cloud_off, size: 16, color: HazardColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              seen == null ? what : l10n.lastSeen(what, l10n.timeAgo(seen)),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _Indicators extends StatelessWidget {
  const _Indicators({required this.node});
  final NodeAnalysis node;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      // Not reporting: the hub already says "No data"; dim so it reads as not live.
      opacity: node.isLive ? 1 : 0.55,
      child: Column(children: [for (final i in node.indicators) _IndicatorRow(indicator: i)]),
    );
  }
}

class _IndicatorRow extends StatelessWidget {
  const _IndicatorRow({required this.indicator});
  final Indicator indicator;

  @override
  Widget build(BuildContext context) {
    final i = indicator;
    final l10n = context.l10n;
    final color = context.palette.ink(HazardColors.forLevel(i.level));
    final trend = _trendIcon(i.trend);
    final flagged = i.level == 'attention' || i.level == 'danger';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: flagged ? BoxDecoration(color: color.withAlpha(28), borderRadius: BorderRadius.circular(6)) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_indicatorIcon(i.key), size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              i.label.isNotEmpty ? i.label : l10n.indicatorLabel(i.key),
              style: TextStyle(color: context.palette.muted),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  i.value,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: switch (i.level) {
                      'danger' => HazardColors.alarm,
                      'ok' || 'attention' => null,
                      _ => context.palette.faint,
                    },
                  ),
                ),
                if (i.detail != null)
                  Text(
                    i.detail!,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 12, color: context.palette.muted),
                  ),
              ],
            ),
          ),
          if (trend != null) ...[
            const SizedBox(width: 4),
            Icon(trend, size: 16, color: context.palette.faint, semanticLabel: l10n.trendLabel(i.trend)),
          ],
        ],
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(context.l10n.loadingSensorStatus, style: TextStyle(color: context.palette.muted)),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cloud_off, color: HazardColors.unknown),
        title: Text(context.l10n.sensorStatusUnavailable),
        subtitle: Text(context.l10n.hubUnreachable),
      ),
    );
  }
}

class _NoSensorsCard extends StatelessWidget {
  const _NoSensorsCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.sensors_off, color: HazardColors.unknown),
        title: Text(context.l10n.noSensorsConnected),
        subtitle: Text(context.l10n.noSensorsHint),
      ),
    );
  }
}

class _RefreshFailedNote extends StatelessWidget {
  const _RefreshFailedNote({required this.updatedAt});
  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    final at = updatedAt;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.sync_problem, size: 16, color: HazardColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              at == null ? l10n.refreshFailed : l10n.refreshFailedShowingFrom(l10n.clockTime(at)),
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

String _headline(BuildContext context, NodeAnalysis node) =>
    node.headline.isNotEmpty ? node.headline : context.l10n.analysisStatus(node.status);

IconData _statusIcon(String status) => switch (status) {
      'ok' => Icons.verified_user,
      'attention' => Icons.error_outline,
      'danger' => Icons.warning_rounded,
      _ => Icons.help_outline,
    };

IconData _kindIcon(String kind) => switch (kind) {
      'air' => Icons.air,
      'water' => Icons.water_damage,
      _ => Icons.sensors,
    };

/// Icon per indicator key (HARDWARE.md §3); fallback labels: `indicatorLabel()`.
IconData _indicatorIcon(String key) => switch (key) {
      'air_quality' => Icons.grain,
      'co' => Icons.cloud,
      'gas' => Icons.local_fire_department,
      'comfort' => Icons.thermostat,
      'occupancy' => Icons.person,
      'leak' => Icons.water_drop,
      'valve' => Icons.plumbing,
      'health' => Icons.sensors,
      _ => Icons.info_outline,
    };

IconData? _trendIcon(String? trend) => switch (trend) {
      'rising' => Icons.trending_up,
      'falling' => Icons.trending_down,
      'stable' => Icons.trending_flat,
      _ => null,
    };
