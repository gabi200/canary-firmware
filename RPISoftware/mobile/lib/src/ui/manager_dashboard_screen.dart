import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/incident.dart';
import '../logic/display_labels.dart';
import '../state/dashboard_providers.dart';
import '../state/incident_controller.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'settings_screen.dart';
import 'widgets/flashing_evacuate_banner.dart';
import 'widgets/home_status_section.dart';
import 'widgets/status_pill.dart';

/// Operations dashboard for managers / dispatchers / admins — the mobile counterpart
/// of the web console: active incidents, victim-accounting, named resident roster and
/// the manager actions (order evacuation / resolve / dismiss).
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
    try {
      await ref.read(apiClientProvider).incidentAction(incident.id, action);
      await _refresh();
      messenger.showSnackBar(SnackBar(content: Text('Done: ${action.replaceAll('-', ' ')}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: HazardColors.alarm));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(incidentControllerProvider);
    final summary = ref.watch(summaryProvider).summary;
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;
    final primary = _primary(state);

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
        title: Text(summary?.buildingName ?? 'Canary'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: StatusPill(state: primary?.state ?? 'normal', label: primary == null ? 'all clear' : null)),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConnectivityRow(connected: state.connected),
            const SizedBox(height: 12),
            if (primary != null && primary.isEvacuation) ...[
              FlashingEvacuateBanner(incident: primary, zoneLabel: prettyZone(labels, primary.primaryZoneId)),
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
              const _AllClearCard(),
            const SizedBox(height: 16),
            const HomeStatusSection(title: 'Building sensors'),
            const SizedBox(height: 24),
            Text('Active incidents', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (state.incidents.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.check_circle, color: HazardColors.normal),
                  title: Text('No active incidents'),
                  subtitle: Text('Building is being monitored.'),
                ),
              )
            else
              for (final inc in state.incidents)
                Card(
                  child: ListTile(
                    leading: Icon(Icons.warning_amber_rounded, color: HazardColors.forState(inc.state)),
                    title: Text(inc.hazardLabel),
                    subtitle: Text('${incidentStateLabel(inc.state)} · ${prettyZone(labels, inc.primaryZoneId)}'),
                    trailing: StatusPill(state: inc.state),
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
        Icon(connected ? Icons.wifi : Icons.wifi_off,
            size: 18, color: connected ? HazardColors.normal : HazardColors.unknown),
        const SizedBox(width: 6),
        Text(connected ? 'Live' : 'Reconnecting…', style: const TextStyle(color: HazardColors.onSurfaceMuted)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Victim accounting', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            acc.when(
              loading: () => const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
              error: (e, _) => const Text('Could not load accounting', style: TextStyle(color: HazardColors.alarm)),
              data: (a) => Row(
                children: [
                  _Metric(value: a.occupancyTotal.round().toString(), label: 'Occupants'),
                  _Metric(value: a.accounted.toString(), label: 'Accounted', color: HazardColors.normal),
                  _Metric(value: a.unaccounted.toString(), label: 'Unaccounted', color: a.unaccounted > 0 ? HazardColors.alarm : HazardColors.normal),
                  _Metric(value: a.needsHelp.toString(), label: 'Need help', color: a.needsHelp > 0 ? HazardColors.alarm : null),
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
          Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: HazardColors.onSurfaceMuted)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Resident accountability', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            roster.when(
              loading: () => const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
              error: (e, _) => const Text('Could not load roster', style: TextStyle(color: HazardColors.alarm)),
              data: (r) => r.entries.isEmpty
                  ? const Text('No residents registered.', style: TextStyle(color: HazardColors.onSurfaceMuted))
                  : Column(
                      children: [
                        for (final e in r.entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(e.displayName),
                            subtitle: Text([
                              e.unitLabel ?? humanizeId(e.unitId),
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

  ({String label, Color color}) get _meta {
    switch (status) {
      case 'needs_help':
        return (label: 'NEEDS HELP', color: HazardColors.alarm);
      case 'safe_outside':
        return (label: 'Safe — out', color: HazardColors.normal);
      case 'safe_inside':
        return (label: 'Safe — in', color: HazardColors.normal);
      case 'no_response':
        return (label: 'No response', color: HazardColors.warning);
      default:
        return (label: 'Awaiting', color: HazardColors.warning);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: m.color.withOpacity(0.15),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: HazardColors.warning, minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.directions_run),
              label: const Text('Order evacuation'),
              onPressed: busy || incident.isEvacuation ? null : () => onAction(incident, 'order-evacuation'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Resolve'),
              onPressed: busy || !alarming ? null : () => onAction(incident, 'resolve'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44), foregroundColor: HazardColors.alarm),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Dismiss'),
              // Once residents are alarmed a false-alarm dismissal is illegal (backend 409).
              onPressed: busy || alarming ? null : () => onAction(incident, 'dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllClearCard extends StatelessWidget {
  const _AllClearCard();
  @override
  Widget build(BuildContext context) {
    return Card(
      color: HazardColors.normal.withOpacity(0.08),
      child: const Padding(
        padding: EdgeInsets.all(24),
        child: Row(
          children: [
            Icon(Icons.verified_user, color: HazardColors.normal, size: 40),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('All clear', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  SizedBox(height: 4),
                  Text('No active hazard in this building.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
