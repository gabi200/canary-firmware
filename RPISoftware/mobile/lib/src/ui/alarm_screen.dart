import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/check_in.dart';
import '../models/evacuation.dart';
import '../models/incident.dart';
import '../state/incident_controller.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'widgets/evacuation_map.dart';

class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.incidentId});
  final String incidentId;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  CheckInStatus? _checkedInAs;
  bool _submitting = false;

  Incident? _find(IncidentsState s) {
    for (final i in s.incidents) {
      if (i.id == widget.incidentId) return i;
    }
    return null;
  }

  Future<void> _checkIn(CheckInStatus status) async {
    setState(() => _submitting = true);
    final result = await ref
        .read(incidentControllerProvider.notifier)
        .submitCheckIn(widget.incidentId, status);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _checkedInAs = status;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result == CheckInResult.sent
            ? 'Check-in sent: ${status.label}'
            : 'Offline — check-in queued, will send automatically'),
        backgroundColor: result == CheckInResult.sent ? Colors.green.shade800 : Colors.orange.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(incidentControllerProvider);
    final incident = _find(state);

    if (incident == null || incident.isClosed) {
      return _AllClear(onClose: () => Navigator.of(context).maybePop());
    }

    final color = HazardColors.forState(incident.state);
    return Scaffold(
      backgroundColor: color,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const Spacer(),
                  Text('LIVE', style: TextStyle(color: Colors.white.withOpacity(0.8), fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                incident.isEvacuation ? 'EVACUATE NOW' : incident.hazardLabel.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                '${incident.hazardLabel} detected · ${incident.primaryZoneId ?? ''}',
                style: const TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 24),
              _GuidanceCard(incident: incident),
              const SizedBox(height: 24),
              _CheckInCard(
                submitting: _submitting,
                checkedInAs: _checkedInAs,
                onCheckIn: _checkIn,
              ),
              const SizedBox(height: 16),
              const Text(
                'If you are in immediate danger, call 112.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuidanceCard extends ConsumerWidget {
  const _GuidanceCard({required this.incident});
  final Incident incident;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final evac = ref.watch(evacuationProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.directions_run, color: Color(0xFFB71C1C)),
                SizedBox(width: 8),
                Text('Evacuation guidance', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            evac.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const _StaticFallback(),
              data: (info) => _RouteView(info: info, avoidZone: incident.primaryZoneId),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteView extends StatelessWidget {
  const _RouteView({required this.info, this.avoidZone});
  final EvacuationInfo info;
  final String? avoidZone;

  @override
  Widget build(BuildContext context) {
    if (info.routes.isEmpty) return const _StaticFallback();
    // Prefer a route that does not start at the hazard zone (route away from source).
    final route = info.routes.firstWhere(
      (r) => r.fromZoneId != avoidZone,
      orElse: () => info.routes.first,
    );
    final assembly = info.assemblyById(route.toAssemblyPointId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(route.label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        EvacuationMap(route: route, assembly: assembly),
        const SizedBox(height: 12),
        for (var i = 0; i < route.path.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                const SizedBox(width: 10),
                Expanded(child: Text(route.path[i])),
              ],
            ),
          ),
        if (assembly != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Icon(Icons.flag, color: Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              Expanded(child: Text('Assembly point: ${assembly.label}', style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
      ],
    );
  }
}

class _StaticFallback extends StatelessWidget {
  const _StaticFallback();
  @override
  Widget build(BuildContext context) {
    return const ListTile(
      leading: Icon(Icons.map, color: Colors.black54),
      title: Text('Use the nearest marked exit'),
      subtitle: Text('Take the stairs (not the lift) to the outdoor assembly point. Do not return inside.'),
      contentPadding: EdgeInsets.zero,
    );
  }
}

class _CheckInCard extends StatelessWidget {
  const _CheckInCard({required this.submitting, required this.checkedInAs, required this.onCheckIn});
  final bool submitting;
  final CheckInStatus? checkedInAs;
  final void Function(CheckInStatus) onCheckIn;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Are you safe?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Your check-in helps responders know who is still inside.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            if (checkedInAs != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle, color: Color(0xFF2E7D32)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Checked in: ${checkedInAs!.label}')),
                ]),
              )
            else ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
                icon: const Icon(Icons.verified),
                label: Text(CheckInStatus.safeOutside.label),
                onPressed: submitting ? null : () => onCheckIn(CheckInStatus.safeOutside),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: submitting ? null : () => onCheckIn(CheckInStatus.safeInside),
                child: Text(CheckInStatus.safeInside.label),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
                icon: const Icon(Icons.sos),
                label: Text(CheckInStatus.needsHelp.label),
                onPressed: submitting ? null : () => onCheckIn(CheckInStatus.needsHelp),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AllClear extends StatelessWidget {
  const _AllClear({required this.onClose});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2E7D32),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.verified_user, color: Colors.white, size: 96),
              const SizedBox(height: 16),
              const Text('All clear', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('The hazard has cleared.', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF2E7D32)),
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
