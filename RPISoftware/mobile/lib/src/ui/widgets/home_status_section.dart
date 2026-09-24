import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/summary.dart';
import '../../state/dashboard_providers.dart';
import '../../state/providers.dart';
import '../../theme.dart';
import 'status_pill.dart';

/// "Home status": the hub's analysis of the building's sensors — an overall
/// card, then one card per zone with each sensor's headline and indicators.
/// Analysis only (HARDWARE.md §3): never raw measurements.
class HomeStatusSection extends ConsumerWidget {
  const HomeStatusSection({super.key, this.title = 'Home status'});
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(summaryProvider);
    final summary = state.summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (summary != null && state.error != null) _RefreshFailedNote(updatedAt: state.updatedAt),
        if (summary == null)
          state.error == null ? const _LoadingCard() : const _UnavailableCard()
        else if (!summary.hasNodes)
          const _NoSensorsCard()
        else ...[
          _OverallCard(summary: summary),
          for (final zone in summary.zones)
            if (zone.nodes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ZoneCard(zone: zone),
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
    final color = HazardColors.forLevel(summary.status);
    final incidents = summary.activeIncidents;
    return Card(
      color: color.withAlpha(20),
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
                    summary.headline.isNotEmpty ? summary.headline : _statusText(summary.status),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      '${summary.nodesOnline} of ${summary.nodesTotal} sensors online',
                      if (incidents > 0) '$incidents active incident${incidents == 1 ? '' : 's'}',
                    ].join(' · '),
                    style: const TextStyle(color: Colors.black54),
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

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({required this.zone});
  final ZoneSummary zone;

  @override
  Widget build(BuildContext context) {
    final label = zone.zoneLabel.isNotEmpty ? zone.zoneLabel : prettyZone(null, zone.zoneId);
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
                Icon(Icons.circle, size: 12, color: HazardColors.forLevel(zone.status)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (occupied != null)
                  StatusPill(
                    state: 'occupancy',
                    label: occupied ? 'occupied' : 'empty',
                    color: occupied ? HazardColors.info : HazardColors.unknown,
                  ),
              ],
            ),
          ),
          for (var i = 0; i < zone.nodes.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            _NodeTile(node: zone.nodes[i], zoneLabel: label),
          ],
        ],
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.node, required this.zoneLabel});
  final NodeAnalysis node;
  final String zoneLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _NodeSheet(initial: node, zoneLabel: zoneLabel),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(_kindIcon(node.kind), size: 20, color: Colors.black54),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _NodeStatusPill(node: node),
                const Icon(Icons.chevron_right, color: Colors.black38),
              ],
            ),
            const SizedBox(height: 6),
            if (!node.isLive) ...[_NotReporting(node: node), const SizedBox(height: 6)],
            Text(_headline(node), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            _Indicators(node: node),
          ],
        ),
      ),
    );
  }
}

/// All indicators + advice for one sensor. Watches the provider so it stays
/// current while open.
class _NodeSheet extends ConsumerWidget {
  const _NodeSheet({required this.initial, required this.zoneLabel});
  final NodeAnalysis initial;
  final String zoneLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final node = ref.watch(summaryProvider).summary?.node(initial.nodeId) ?? initial;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(
            children: [
              Icon(_kindIcon(node.kind), color: Colors.black54),
              const SizedBox(width: 10),
              Expanded(child: Text(node.name, style: Theme.of(context).textTheme.titleLarge)),
              _NodeStatusPill(node: node),
            ],
          ),
          const SizedBox(height: 4),
          Text('$zoneLabel · ${_kindLabel(node.kind)}', style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          if (!node.isLive) ...[_NotReporting(node: node), const SizedBox(height: 12)],
          Text(_headline(node), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          _Indicators(node: node),
          if (node.advice.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('What to do', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
        ],
      ),
    );
  }
}

class _NodeStatusPill extends StatelessWidget {
  const _NodeStatusPill({required this.node});
  final NodeAnalysis node;

  @override
  Widget build(BuildContext context) {
    if (!node.online) return const StatusPill(state: 'offline', color: HazardColors.unknown);
    if (node.stale) return const StatusPill(state: 'stale', label: 'no data', color: HazardColors.unknown);
    return StatusPill(state: node.status, color: HazardColors.forLevel(node.status));
  }
}

/// Offline / stale warning strip.
class _NotReporting extends StatelessWidget {
  const _NotReporting({required this.node});
  final NodeAnalysis node;

  @override
  Widget build(BuildContext context) {
    final what = node.online ? 'No recent data' : 'Offline';
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
              seen == null ? what : '$what · last seen ${_ago(seen)}',
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
    final color = HazardColors.forLevel(i.level);
    final meta = _indicatorMeta(i.key);
    final trend = _trendIcon(i.trend);
    final flagged = i.level == 'attention' || i.level == 'danger';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: flagged
          ? BoxDecoration(color: color.withAlpha(28), borderRadius: BorderRadius.circular(6))
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(meta.icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              i.label.isNotEmpty ? i.label : meta.label,
              style: const TextStyle(color: Colors.black54),
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
                      _ => Colors.black45,
                    },
                  ),
                ),
                if (i.detail != null)
                  Text(
                    i.detail!,
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
              ],
            ),
          ),
          if (trend != null) ...[
            const SizedBox(width: 4),
            Icon(trend, size: 16, color: Colors.black45, semanticLabel: i.trend),
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
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 12),
            Expanded(child: Text('Loading sensor status…', style: TextStyle(color: Colors.black54))),
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
    return const Card(
      child: ListTile(
        leading: Icon(Icons.cloud_off, color: HazardColors.unknown),
        title: Text('Sensor status unavailable'),
        subtitle: Text("Can't reach the hub right now. Pull down to retry."),
      ),
    );
  }
}

class _NoSensorsCard extends StatelessWidget {
  const _NoSensorsCard();
  @override
  Widget build(BuildContext context) {
    return const Card(
      child: ListTile(
        leading: Icon(Icons.sensors_off, color: HazardColors.unknown),
        title: Text('No sensors connected'),
        subtitle: Text('Sensor status appears here once a Canary device joins the hub.'),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.sync_problem, size: 16, color: HazardColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              at == null ? "Couldn't refresh sensor status" : "Couldn't refresh · showing status from ${_ago(at)}",
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}

String _headline(NodeAnalysis node) => node.headline.isNotEmpty ? node.headline : _statusText(node.status);

String _statusText(String status) => switch (status) {
      'ok' => 'All clear',
      'attention' => 'Needs attention',
      'danger' => 'Danger',
      _ => 'Status unknown',
    };

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

String _kindLabel(String kind) => switch (kind) {
      'air' => 'Air sensor',
      'water' => 'Water sensor',
      _ => 'Sensor',
    };

/// Icon + fallback label per indicator key (HARDWARE.md §3).
({IconData icon, String label}) _indicatorMeta(String key) => switch (key) {
      'air_quality' => (icon: Icons.grain, label: 'Air quality'),
      'co' => (icon: Icons.cloud, label: 'Carbon monoxide'),
      'gas' => (icon: Icons.local_fire_department, label: 'Gas'),
      'comfort' => (icon: Icons.thermostat, label: 'Comfort'),
      'occupancy' => (icon: Icons.person, label: 'Occupancy'),
      'leak' => (icon: Icons.water_drop, label: 'Water leak'),
      'valve' => (icon: Icons.plumbing, label: 'Water valve'),
      'health' => (icon: Icons.sensors, label: 'Sensor'),
      _ => (icon: Icons.info_outline, label: key),
    };

IconData? _trendIcon(String? trend) => switch (trend) {
      'rising' => Icons.trending_up,
      'falling' => Icons.trending_down,
      'stable' => Icons.trending_flat,
      _ => null,
    };

String _ago(DateTime ts) {
  final d = DateTime.now().difference(ts);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}
