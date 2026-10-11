import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../models/incident.dart';
import '../state/building_status.dart';
import '../state/dashboard_providers.dart';
import '../state/incident_controller.dart';
import '../state/providers.dart';
import '../state/scope_providers.dart';
import '../theme.dart';
import 'sensor_test_screen.dart';
import 'settings_screen.dart';
import 'widgets/flashing_evacuate_banner.dart';
import 'widgets/home_status_section.dart';
import 'widgets/node_commands.dart';
import 'widgets/safety_sign.dart';
import 'widgets/status_hero.dart';
import 'widgets/status_pill.dart';
import 'widgets/unit_scope_bar.dart';

/// Operations dashboard for managers / dispatchers / admins — the mobile counterpart
/// of the web console: active incidents, victim-accounting, named resident roster and
/// the manager actions (order evacuation / resolve / dismiss). The apartment
/// picker is pinned at the top and narrows the sensor list; incidents and the
/// roster always stay whole-building.
class ManagerDashboardScreen extends ConsumerStatefulWidget {
  const ManagerDashboardScreen({super.key});

  @override
  ConsumerState<ManagerDashboardScreen> createState() => _ManagerDashboardScreenState();
}

class _ManagerDashboardScreenState extends ConsumerState<ManagerDashboardScreen> {
  bool _busy = false;

  Future<void> _refresh() async {
    final sensors = ref.read(summaryProvider.notifier).refresh();
    await ref.read(incidentControllerProvider.notifier).refresh();
    final primary = _primary(ref.read(incidentControllerProvider));
    if (primary != null) {
      ref.invalidate(accountingProvider(primary.id));
      ref.invalidate(rosterProvider(primary.id));
    }
    ref.invalidate(zoneLabelsProvider);
    await sensors;
  }

  Incident? _primary(IncidentsState s) => s.incidents.isEmpty ? null : s.incidents.first;

  Future<void> _action(Incident incident, String action) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await ref.read(apiClientProvider).incidentAction(incident.id, action);
      await _refresh();
      final done = switch (action) {
        'order-evacuation' => l10n.evacuationOrdered,
        'resolve' => l10n.incidentResolved,
        'dismiss' => l10n.incidentDismissed,
        _ => action,
      };
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(l10n.actionFailed(l10n.errorReason(e))),
        backgroundColor: HazardColors.alarm,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final state = ref.watch(incidentControllerProvider);
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;
    final zones = ref.watch(zonesInfoProvider).valueOrNull;
    final scope = ref.watch(summaryScopeProvider);
    final primary = _primary(state);
    final l10n = context.l10n;
    final status = buildingStatusOf(state, ref.watch(summaryProvider));
    // Every flat has a "Bucătărie": name the zone with its unit.
    String zoneName(String? id) => zoneWithUnit(labels, zones, id);

    // Live update: any WebSocket frame (incident transition or resident check-in)
    // bumps eventSeq — refetch accounting + roster for the active incident.
    ref.listen<IncidentsState>(incidentControllerProvider, (prev, next) {
      if (prev?.eventSeq == next.eventSeq) return;
      final p = _primary(next);
      if (p != null) {
        ref.invalidate(accountingProvider(p.id));
        ref.invalidate(rosterProvider(p.id));
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(session?.buildingId ?? 'Canary'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: primary == null ? BuildingStatusPill(status: status) : StatusPill(state: primary.state),
            ),
          ),
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
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            if (scope.hasPicker) UnitScopeHeader(scope: scope),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  _ConnectivityRow(connected: state.connected),
                  const SizedBox(height: 12),
                  if (primary != null && primary.isEvacuation) ...[
                    FlashingEvacuateBanner(incident: primary, zoneLabel: zoneName(primary.primaryZoneId)),
                    const SizedBox(height: 16),
                  ],
                  if (primary != null) ...[
                    _AccountingCard(incidentId: primary.id),
                    const SizedBox(height: 16),
                    _ManagerActions(incident: primary, busy: _busy, onAction: _action),
                    const SizedBox(height: 16),
                    _RosterCard(incidentId: primary.id),
                    const SizedBox(height: 16),
                  ] else
                    StatusHeroCard(status: status, forManager: true),
                  const SizedBox(height: 16),
                  if (roleCanCommand(session?.role)) ...[
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.notifications_active_outlined),
                        title: Text(l10n.testBuildingSensors),
                        subtitle: Text(l10n.testBuildingSensorsSubtitle),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SensorTestScreen())),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  HomeStatusSection(title: l10n.buildingSensors),
                  const SizedBox(height: 24),
                  Text(l10n.activeIncidents, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (state.incidents.isEmpty)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.check_circle, color: HazardColors.normal),
                        title: Text(l10n.noActiveIncidents),
                        subtitle: Text(l10n.buildingMonitored),
                      ),
                    )
                  else
                    for (final inc in state.incidents)
                      Card(
                        child: ListTile(
                          leading: SafetySignImage(hazardSign(inc.hazardType), size: 36),
                          title: Text(l10n.hazardName(inc.hazardType)),
                          subtitle: Text('${l10n.statusLabel(inc.state)} · ${zoneName(inc.primaryZoneId)}'),
                          trailing: StatusPill(state: inc.state),
                        ),
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

class _ConnectivityRow extends StatelessWidget {
  const _ConnectivityRow({required this.connected});
  final bool connected;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(connected ? Icons.wifi : Icons.wifi_off, size: 18, color: connected ? context.palette.ink(HazardColors.normal) : context.palette.faint),
        const SizedBox(width: 6),
        Text(connected ? context.l10n.live : context.l10n.reconnecting,
            style: TextStyle(color: context.palette.muted)),
      ],
    );
  }
}

class _AccountingCard extends ConsumerWidget {
  const _AccountingCard({required this.incidentId});
  final String incidentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acc = ref.watch(accountingProvider(incidentId));
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.victimAccounting, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            acc.when(
              skipLoadingOnReload: true, // language switch: keep the numbers up while refetching
              loading: () => const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
              error: (e, _) => Text(l10n.couldNotLoadAccounting, style: const TextStyle(color: HazardColors.alarm)),
              data: (a) => Row(
                children: [
                  _Metric(value: l10n.count(a.occupancyTotal.round()), label: l10n.metricOccupants),
                  _Metric(value: l10n.count(a.accounted), label: l10n.metricAccounted, color: HazardColors.normal),
                  _Metric(value: l10n.count(a.unaccounted), label: l10n.metricUnaccounted, color: a.unaccounted > 0 ? HazardColors.alarm : HazardColors.normal),
                  _Metric(value: l10n.count(a.needsHelp), label: l10n.metricNeedHelp, color: a.needsHelp > 0 ? HazardColors.alarm : null),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.label, this.color});
  final String value;
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 2),
          Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: context.palette.muted)),
        ],
      ),
    );
  }
}

class _RosterCard extends ConsumerWidget {
  const _RosterCard({required this.incidentId});
  final String incidentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roster = ref.watch(rosterProvider(incidentId));
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.residentAccountability, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            roster.when(
              skipLoadingOnReload: true, // language switch: keep the roster up while refetching
              loading: () => const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
              error: (e, _) => Text(l10n.couldNotLoadRoster, style: const TextStyle(color: HazardColors.alarm)),
              data: (r) => r.entries.isEmpty
                  ? Text(l10n.noResidentsRegistered, style: TextStyle(color: context.palette.muted))
                  : Column(
                      children: [
                        for (final e in r.entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(e.displayName),
                            subtitle: Text([
                              e.unitLabel ?? e.unitId ?? '—',
                              if (e.phone != null && e.phone!.isNotEmpty) e.phone!,
                            ].join(' · ')),
                            trailing: _RosterStatusChip(status: e.status),
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

class _RosterStatusChip extends StatelessWidget {
  const _RosterStatusChip({required this.status});
  final String status;

  ({String label, Color color}) _meta(AppLocalizations l10n) {
    switch (status) {
      case 'needs_help':
        return (label: l10n.rosterNeedsHelp, color: HazardColors.alarm);
      case 'safe_outside':
        return (label: l10n.rosterSafeOutside, color: HazardColors.normal);
      case 'safe_inside':
        return (label: l10n.rosterSafeInside, color: HazardColors.normal);
      case 'no_response':
        return (label: l10n.rosterNoResponse, color: HazardColors.warning);
      default:
        return (label: l10n.rosterAwaiting, color: HazardColors.warning);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta(context.l10n);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: m.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: m.color, width: 1.5),
      ),
      child: Text(m.label, style: TextStyle(color: m.color, fontWeight: FontWeight.w700, fontSize: 11)),
    );
  }
}

class _ManagerActions extends StatelessWidget {
  const _ManagerActions({required this.incident, required this.busy, required this.onAction});
  final Incident incident;
  final bool busy;
  final Future<void> Function(Incident, String) onAction;

  @override
  Widget build(BuildContext context) {
    final alarming = incident.isAlarming;
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: HazardColors.warning, minimumSize: const Size(0, 44)),
              icon: const SafetySignImage(SafetySign.e002, size: 24, decorative: true),
              label: Text(l10n.orderEvacuation),
              onPressed: busy || incident.isEvacuation ? null : () => onAction(incident, 'order-evacuation'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(l10n.resolve),
              onPressed: busy || !alarming ? null : () => onAction(incident, 'resolve'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), foregroundColor: HazardColors.alarm),
              icon: const Icon(Icons.cancel_outlined),
              label: Text(l10n.dismiss),
              // Once residents are alarmed a false-alarm dismissal is illegal (backend 409).
              onPressed: busy || alarming ? null : () => onAction(incident, 'dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}
