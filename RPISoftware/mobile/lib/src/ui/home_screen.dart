import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/display_labels.dart';
import '../models/evacuation.dart';
import '../state/dashboard_providers.dart';
import '../state/incident_controller.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'alarm_screen.dart';
import 'settings_screen.dart';
import 'widgets/hazard_banner.dart';
import 'widgets/home_status_section.dart';
import 'widgets/status_pill.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _prefetchedEvacuation = false;

  void _openAlarm(BuildContext context, String incidentId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AlarmScreen(incidentId: incidentId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(incidentControllerProvider);
    final summary = ref.watch(summaryProvider).summary;
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;

    // Warm the offline route cache before an incident. A later alarm screen
    // reads the same provider and can use the last successful response.
    if (!_prefetchedEvacuation && ref.watch(sessionProvider) != null) {
      _prefetchedEvacuation = true;
      ref.read(evacuationProvider.future).catchError(
        (_) => const EvacuationInfo(routes: [], assemblyPoints: []),
      );
    }

    // Auto-surface the emergency screen when the building enters an alarming state.
    ref.listen<IncidentsState>(incidentControllerProvider, (prev, next) {
      final wasAlarming = prev?.activeAlarm != null;
      final alarm = next.activeAlarm;
      if (!wasAlarming && alarm != null) {
        _openAlarm(context, alarm.id);
      }
    });

    final alarm = state.activeAlarm;

    return Scaffold(
      appBar: AppBar(
        title: Text(summary?.buildingName ?? 'Canary'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: StatusPill(state: alarm?.state ?? 'normal', label: alarm == null ? 'all clear' : null)),
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
        onRefresh: () async {
          await Future.wait([
            ref.read(incidentControllerProvider.notifier).refresh(),
            ref.read(summaryProvider.notifier).refresh(),
          ]);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConnectivityRow(connected: state.connected, pending: state.pending),
            const SizedBox(height: 12),
            if (alarm != null) ...[
              HazardBanner(
                incident: alarm,
                zoneLabel: prettyZone(labels, alarm.primaryZoneId),
                onTap: () => _openAlarm(context, alarm.id),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.directions_run),
                label: const Text('Open evacuation guidance'),
                onPressed: () => _openAlarm(context, alarm.id),
              ),
            ] else
              const _AllClearCard(),
            const SizedBox(height: 24),
            const HomeStatusSection(),
            const SizedBox(height: 24),
            Text('Active incidents', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (state.incidents.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.check_circle, color: HazardColors.normal),
                  title: Text('No active incidents'),
                  subtitle: Text('Your building is being monitored.'),
                ),
              )
            else
              for (final inc in state.incidents)
                Card(
                  child: ListTile(
                    leading: Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error),
                    title: Text(inc.hazardLabel),
                    subtitle: Text('${incidentStateLabel(inc.state)} · ${prettyZone(labels, inc.primaryZoneId)}'),
                    trailing: StatusPill(state: inc.state),
                    onTap: inc.isAlarming ? () => _openAlarm(context, inc.id) : null,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _ConnectivityRow extends StatelessWidget {
  const _ConnectivityRow({required this.connected, required this.pending});
  final bool connected;
  final int pending;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(connected ? Icons.wifi : Icons.wifi_off,
            size: 18, color: connected ? HazardColors.normal : HazardColors.unknown),
        const SizedBox(width: 6),
        Text(connected ? 'Live' : 'Reconnecting…', style: const TextStyle(color: HazardColors.onSurfaceMuted)),
        const Spacer(),
        if (pending > 0)
          Row(children: [
            const Icon(Icons.cloud_upload, size: 18, color: HazardColors.warning),
            const SizedBox(width: 6),
            Text('$pending check-in${pending == 1 ? '' : 's'} queued', style: const TextStyle(color: HazardColors.warning)),
          ]),
      ],
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
                  Text('No active hazard. You will be alerted immediately if anything is detected.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
