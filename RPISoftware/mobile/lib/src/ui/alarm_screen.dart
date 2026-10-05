import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../logic/hazard_advice.dart';
import '../logic/route_selection.dart';
import '../models/check_in.dart';
import '../models/incident.dart';
import '../state/dashboard_providers.dart';
import '../state/incident_controller.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'widgets/route_line.dart';

class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.incidentId});
  final String incidentId;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  CheckInStatus? _checkedInAs;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Incident? _find(IncidentsState state) {
    for (final incident in state.incidents) {
      if (incident.id == widget.incidentId) return incident;
    }
    return null;
  }

  Future<void> _checkIn(CheckInStatus status) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final result = await ref
        .read(incidentControllerProvider.notifier)
        .submitCheckIn(widget.incidentId, status);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _checkedInAs = status;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result == CheckInResult.sent
          ? 'Check-in sent: ${status.label}'
          : 'Offline — check-in queued, will send automatically'),
      backgroundColor: result == CheckInResult.sent
          ? HazardColors.normal : HazardColors.warning,
    ));
  }

  Future<void> _call112() async {
    try {
      if (await launchUrl(Uri(scheme: 'tel', path: '112'))) return;
    } catch (_) {
      // No dialer is available.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Dial 112 on your phone')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(incidentControllerProvider);
    final incident = _find(state);
    if (incident == null || incident.isClosed) {
      return _AllClear(onClose: () => Navigator.of(context).maybePop());
    }
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;
    final zoneName = labels?[incident.primaryZoneId]?.trim();
    final routeState = ref.watch(evacuationProvider);
    final info = routeState.valueOrNull;
    final choice = info == null ? null : selectRoute(info,
      hazardZoneIds: incident.hazardZoneIds, userZoneId: null);

    return Scaffold(
      backgroundColor: HazardColors.surface,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: Container(
            color: HazardColors.forState(incident.state),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: HazardColors.onHazard),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(state.connected ? 'Live' : 'Offline · showing saved route',
                      style: const TextStyle(color: HazardColors.onHazard,
                        fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                )),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.expand_more),
                  label: const Text('Minimize'),
                  style: TextButton.styleFrom(
                    foregroundColor: HazardColors.onHazard,
                    minimumSize: const Size(48, 48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 12),
              Text(incident.isEvacuation ? 'EVACUATE NOW'
                    : incident.hazardLabel.toUpperCase(),
                style: const TextStyle(color: HazardColors.onHazard,
                  fontSize: 32, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(zoneName == null || zoneName.isEmpty ? incident.hazardLabel
                    : '${incident.hazardLabel} · $zoneName',
                style: const TextStyle(color: HazardColors.onHazard, fontSize: 18)),
            ]),
          )),
          SliverToBoxAdapter(child: Container(
            color: HazardColors.warnBg,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.warning_amber_rounded, color: HazardColors.warnFg),
              const SizedBox(width: 10),
              Expanded(child: Text(hazardDont(incident.hazardType),
                style: const TextStyle(color: HazardColors.warnFg,
                  fontSize: 16, fontWeight: FontWeight.bold))),
            ]),
          )),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            sliver: SliverToBoxAdapter(child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (choice?.crossesHazard ?? false) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: HazardColors.alarm, width: 2),
                      borderRadius: BorderRadius.circular(12)),
                    child: const Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_rounded, color: HazardColors.alarm),
                        SizedBox(width: 10),
                        Expanded(child: Text(
                          'This route passes near the hazard. Use another marked exit if you can, and call 112.',
                          style: TextStyle(color: HazardColors.text,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                      ]),
                  ),
                  const SizedBox(height: 20),
                ],
                if (choice?.safety == RouteSafety.unknown) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: HazardColors.warnBg,
                      border: Border.all(color: HazardColors.warning, width: 2),
                      borderRadius: BorderRadius.circular(12)),
                    child: const Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, color: HazardColors.warnFg),
                        SizedBox(width: 10),
                        Expanded(child: Text(
                          "We couldn't check this route against the hazard. Follow the marked exits, stay away from the hazard, and call 112 if unsure.",
                          style: TextStyle(color: HazardColors.warnFg,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                      ]),
                  ),
                  const SizedBox(height: 20),
                ],
                const Text('Evacuation route',
                  style: TextStyle(color: HazardColors.text,
                    fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                routeState.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (_, __) => const _StaticFallback(),
                  data: (_) => choice == null || choice.route.waypoints.isEmpty
                    ? const _StaticFallback()
                    : RouteLine(waypoints: choice.route.waypoints,
                        avoidZoneName: zoneName),
                ),
              ],
            )),
          ),
        ]),
      ),
      bottomNavigationBar: _CheckInBar(
        submitting: _submitting,
        checkedInAs: _checkedInAs,
        onCheckIn: _checkIn,
        onChange: () => setState(() => _checkedInAs = null),
        onCall: _call112,
      ),
    );
  }
}

class _StaticFallback extends StatelessWidget {
  const _StaticFallback();
  @override
  Widget build(BuildContext context) {
    return const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.map, color: HazardColors.muted),
      SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Use the nearest marked exit',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          SizedBox(height: 4),
          Text('Take the stairs (not the lift) to the outdoor assembly point. Do not return inside.',
            style: TextStyle(fontSize: 16)),
        ])),
    ]);
  }
}

class _CheckInBar extends StatelessWidget {
  const _CheckInBar({required this.submitting, required this.checkedInAs,
    required this.onCheckIn, required this.onChange, required this.onCall});
  final bool submitting;
  final CheckInStatus? checkedInAs;
  final void Function(CheckInStatus) onCheckIn;
  final VoidCallback onChange;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    return SafeArea(top: false, child: Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.48),
      decoration: const BoxDecoration(color: HazardColors.surface,
        border: Border(top: BorderSide(color: HazardColors.divider))),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: checkedInAs != null
          ? Row(children: [
              const Icon(Icons.check_circle, color: HazardColors.normal),
              const SizedBox(width: 8),
              Expanded(child: Text('Checked in: ${checkedInAs!.label}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              TextButton(onPressed: submitting ? null : onChange,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48),
                  textStyle: const TextStyle(fontSize: 16)),
                child: const Text('Change')),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FilledButton.icon(
                onPressed: submitting ? null : () => onCheckIn(CheckInStatus.safeOutside),
                style: FilledButton.styleFrom(
                  backgroundColor: HazardColors.normal,
                  foregroundColor: HazardColors.onHazard,
                  minimumSize: const Size.fromHeight(56),
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                icon: const Icon(Icons.verified),
                label: const Text("I'm out and safe")),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, constraints) {
                final narrow = constraints.maxWidth < 380 ||
                  MediaQuery.textScalerOf(context).scale(16) > 24;
                final help = FilledButton.icon(
                  onPressed: submitting ? null : () => onCheckIn(CheckInStatus.needsHelp),
                  style: FilledButton.styleFrom(
                    backgroundColor: HazardColors.alarm,
                    foregroundColor: HazardColors.onHazard,
                    minimumSize: const Size.fromHeight(48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  icon: const Icon(Icons.sos), label: const Text('I need help'));
                final call = OutlinedButton.icon(
                  onPressed: onCall,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: HazardColors.text,
                    minimumSize: const Size.fromHeight(48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  icon: const Icon(Icons.phone), label: const Text('Call 112'));
                if (narrow) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [help, const SizedBox(height: 8), call]);
                }
                return Row(children: [Expanded(child: help), const SizedBox(width: 8),
                  Expanded(child: call)]);
              }),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: submitting ? null : () => onCheckIn(CheckInStatus.safeInside),
                style: TextButton.styleFrom(
                  foregroundColor: HazardColors.text,
                  minimumSize: const Size.fromHeight(48),
                  textStyle: const TextStyle(fontSize: 16)),
                icon: const Icon(Icons.home_outlined),
                label: const Text("I'm safe but still inside")),
            ]),
      ),
    ));
  }
}

class _AllClear extends StatelessWidget {
  const _AllClear({required this.onClose});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HazardColors.normal,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.verified_user, color: HazardColors.onHazard, size: 96),
              const SizedBox(height: 16),
              const Text('All clear', style: TextStyle(color: HazardColors.onHazard, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('The hazard has cleared.', style: TextStyle(color: HazardColors.onHazardMuted)),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: HazardColors.surface, foregroundColor: HazardColors.normal),
                onPressed: onClose,
                child: const Text('Return'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
