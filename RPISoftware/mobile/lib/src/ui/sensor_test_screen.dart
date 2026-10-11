import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../logic/node_commands.dart';
import '../logic/unit_scope.dart';
import '../models/node_command.dart';
import '../models/summary.dart';
import '../models/zone_info.dart';
import '../state/command_controller.dart';
import '../state/dashboard_providers.dart';
import '../state/providers.dart';
import '../state/scope_providers.dart';
import '../theme.dart';
import 'widgets/node_commands.dart';
import 'widgets/status_pill.dart';
import 'widgets/unit_scope_bar.dart';

/// "Testează-mi senzorii" (resident: own apartment) / "Testează senzorii"
/// (manager: whole building, narrowed by the apartment picker pinned on top).
/// Sensors grouped by room, each with online / offline, its last test and the
/// test buttons. "Testează toate alarmele": TEST on each online air sensor in
/// view, one after another, with a live checklist — for managers only with one
/// apartment (or room) picked, never the whole building at once. Valves are
/// never closed automatically.
class SensorTestScreen extends ConsumerStatefulWidget {
  const SensorTestScreen({super.key});

  @override
  ConsumerState<SensorTestScreen> createState() => _SensorTestScreenState();
}

class _SensorTestScreenState extends ConsumerState<SensorTestScreen> {
  SequentialTestRunner? _runner;

  /// Test-all checklist: the air sensors of this run (online ones are tested).
  List<NodeAnalysis> _queue = const [];
  DateTime? _runStartedAt;
  bool _running = false;

  @override
  void dispose() {
    _runner?.cancel();
    super.dispose();
  }

  Future<void> _testAll(List<NodeAnalysis> air) async {
    final commands = ref.read(nodeCommandsProvider.notifier);
    final runner = SequentialTestRunner(send: (id) => commands.send(id, NodeCommandType.test));
    setState(() {
      _runner = runner;
      _queue = air;
      _runStartedAt = DateTime.now();
      _running = true;
    });
    await runner.run([for (final n in air) if (n.online) n.nodeId]);
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final role = ref.watch(sessionProvider)?.role;
    final manager = role != 'resident';
    final state = ref.watch(summaryProvider);
    final summary = state.summary;
    final infos = {for (final z in ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[]) z.id: z};
    // A new pick: the last run's checklist belonged to the old one.
    ref.listen<ScopeChoice>(scopeChoiceProvider, (_, __) {
      if (!_running && _queue.isNotEmpty) setState(() => _queue = const []);
    });

    // Rooms with the sensors this user may test; count common-area ones.
    final rooms = <(ZoneSummary, List<NodeAnalysis>)>[];
    var common = 0;
    for (final zone in summary?.zones ?? const <ZoneSummary>[]) {
      final mine = <NodeAnalysis>[];
      for (final n in zone.nodes) {
        switch (commandAccessFor(ref, n)) {
          case CommandAccess.allowed:
            mine.add(n);
          case CommandAccess.commonArea:
            common++;
          case CommandAccess.none:
            break;
        }
      }
      if (mine.isNotEmpty) rooms.add((zone, mine));
    }
    final scope = resolveScope(rooms, infos, ref.watch(scopeChoiceProvider), staff: manager);
    final shown = scope.shown;
    final air = [for (final r in shown) ...r.nodes.where((n) => n.kind == 'air')];
    final scopeLabel = scope.label;
    final canTestAll = !manager || scope.unit != null;
    // Checklist: "Bucătărie · aer", plus the flat when the list spans flats.
    String checklistName(NodeAnalysis n) {
      final r = scope.roomOf(n.zoneId);
      if (r == null) return n.name;
      final name = withRoom(r.label, n.name);
      final unit = r.unitLabel;
      return unit == null || scope.labelOf(r) == r.label ? name : '$name · $unit';
    }

    return Scaffold(
      appBar: AppBar(title: Text(manager ? l10n.testBuildingSensors : l10n.testMySensors)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(summaryProvider.notifier).refresh(),
        child: CustomScrollView(
          slivers: [
            if (scope.hasPicker) UnitScopeHeader(scope: scope),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  if (summary == null)
                    state.error == null
                        ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                        : ListTile(
                            leading: const Icon(Icons.cloud_off, color: HazardColors.unknown),
                            title: Text(l10n.sensorStatusUnavailable),
                            subtitle: Text(l10n.hubUnreachable),
                          )
                  else if (rooms.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.sensors_off, color: HazardColors.unknown),
                      title: Text(l10n.noOwnSensors),
                    )
                  else ...[
                    if (canTestAll || _queue.isNotEmpty) ...[
                      _TestAllCard(
                        running: _running,
                        queue: _queue,
                        startedAt: _runStartedAt,
                        nameOf: checklistName,
                        title: scopeLabel == null ? l10n.testAllAlarms : l10n.testAllAlarmsIn(scopeLabel),
                        noAirText: !canTestAll ? null : (manager ? l10n.testAllNoAirHere : l10n.testAllNoAir),
                        canStart: canTestAll && air.any((n) => n.online),
                        onStart: () => _testAll(air),
                      ),
                      const SizedBox(height: 16),
                    ] else if (scope.hasPicker) ...[
                      _Hint(icon: Icons.touch_app_outlined, text: l10n.testAllPickUnit),
                      const SizedBox(height: 8),
                    ],
                    for (final r in shown) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                        child: Semantics(
                          header: true,
                          // Plain inside a picked flat, "Bucătărie · Ap. 12" across flats.
                          child: Text(scope.labelOf(r), style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ),
                      for (final n in r.nodes) ...[
                        _SensorCard(node: n, showWho: manager),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ],
                  if (!manager && common > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                      child: _Hint(icon: Icons.lock_outline, text: l10n.commonAreaTestNote),
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

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: context.palette.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: context.palette.muted))),
      ],
    );
  }
}

/// A sensor's name with its room in front, unless the name already says it
/// ("Bucătărie · aer" in "Bucatarie" stays as is).
String withRoom(String? room, String name) {
  String plain(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[ăâ]'), 'a')
      .replaceAll('î', 'i')
      .replaceAll(RegExp('[șş]'), 's')
      .replaceAll(RegExp('[țţ]'), 't');
  if (room == null || room.isEmpty || plain(name).contains(plain(room))) return name;
  return '$room · $name';
}

/// "Testează toate alarmele" and its live checklist.
class _TestAllCard extends ConsumerWidget {
  const _TestAllCard({
    required this.running,
    required this.queue,
    required this.startedAt,
    required this.nameOf,
    required this.title,
    required this.noAirText,
    required this.canStart,
    required this.onStart,
  });
  final bool running;
  final List<NodeAnalysis> queue;
  final DateTime? startedAt;
  final String Function(NodeAnalysis node) nameOf;

  /// "Testează toate alarmele", with what is picked ("· Ap. 12").
  final String title;

  /// Why the button is off when nothing can be tested; null: say nothing.
  final String? noAirText;
  final bool canStart;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final runs = ref.watch(nodeCommandsProvider);
    final since = startedAt;
    // A run belongs to this checklist if it started after "Testează toate".
    CommandRun? runOf(NodeAnalysis n) {
      final r = runs[n.nodeId];
      return r != null && since != null && !r.startedAt.isBefore(since) ? r : null;
    }

    final tested = queue.where((n) => n.online).toList();
    final finished = tested.where((n) => runOf(n)?.isFinal ?? false).length;
    final passed = tested.where((n) => runOf(n)?.phase == RunPhase.accepted).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.testAllHint, style: TextStyle(color: context.palette.text)),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: running
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Icon(Icons.notifications_active),
              label: Text(title),
              onPressed: running || !canStart ? null : onStart,
            ),
            if (!canStart && !running && noAirText != null) ...[
              const SizedBox(height: 6),
              Text(noAirText!, style: TextStyle(fontSize: 13, color: context.palette.muted)),
            ],
            if (queue.isNotEmpty) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  running
                      ? l10n.testAllRunning(math.min(finished + 1, tested.length), tested.length)
                      : l10n.testAllDone(passed, tested.length),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 4),
              for (final n in queue)
                _ChecklistRow(
                  label: nameOf(n),
                  online: n.online,
                  run: runOf(n),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.label, required this.online, required this.run});
  final String label;
  final bool online;
  final CommandRun? run;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final r = run;
    final detail = l10n.commandDetail(r?.detail);
    final (Widget icon, String status) = !online
        ? (const Icon(Icons.cloud_off, color: HazardColors.unknown), l10n.checklistSkipped)
        : switch (r?.phase) {
            null => (const Icon(Icons.radio_button_unchecked, color: HazardColors.unknown), l10n.checklistWaiting),
            RunPhase.sending || RunPhase.sent => (
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                l10n.runSent,
              ),
            RunPhase.accepted => (const Icon(Icons.check_circle, color: HazardColors.normal), l10n.runAccepted),
            RunPhase.rejected => (
                const Icon(Icons.warning_amber_rounded, color: Color(0xFFB26A00)),
                detail == null ? l10n.runRejectedPlain : l10n.runRejected(detail),
              ),
            RunPhase.timeout => (const Icon(Icons.help_outline, color: HazardColors.unknown), l10n.runTimeout),
            RunPhase.failed => (
                const Icon(Icons.error_outline, color: HazardColors.alarm),
                l10n.runFailed(l10n.commandFailure(r!.httpStatus, r.detail)),
              ),
          };
    return Semantics(
      container: true,
      label: '$label: $status',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 24, height: 24, child: Center(child: icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(status, style: TextStyle(fontSize: 13, color: context.palette.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One sensor: name, kind, online / offline, then the test panel.
class _SensorCard extends StatelessWidget {
  const _SensorCard({required this.node, required this.showWho});
  final NodeAnalysis node;
  final bool showWho;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(node.kind == 'water' ? Icons.water_damage : Icons.air, color: context.palette.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(l10n.sensorKind(node.kind), style: TextStyle(fontSize: 13, color: context.palette.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(
                  state: node.online ? 'online' : 'offline',
                  label: node.online ? l10n.statusOnline : l10n.statusOffline,
                  color: node.online ? HazardColors.normal : HazardColors.unknown,
                ),
              ],
            ),
            const SizedBox(height: 10),
            NodeCommandPanel(node: node, showTitle: false, showWho: showWho),
          ],
        ),
      ),
    );
  }
}
