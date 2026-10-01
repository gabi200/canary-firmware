import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:intl/intl.dart';

import '../logic/hazard_advice.dart';
import '../logic/connection_status.dart';
import '../logic/evacuation_script.dart';
import '../logic/floor_plan_layout.dart';
import '../logic/route_selection.dart';
import '../models/check_in.dart';
import '../models/incident.dart';
import '../state/dashboard_providers.dart';
import '../state/floor_plan_providers.dart';
import '../state/incident_controller.dart';
import '../state/providers.dart';
import '../services/speech.dart';
import '../theme.dart';
import 'widgets/floor_plan_schematic.dart';
import 'widgets/route_line.dart';
import '../../l10n/gen/app_localizations.dart';

class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.incidentId});
  final String incidentId;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  CheckInStatus? _checkedInAs;
  bool _submitting = false;
  bool _reading = false;
  bool _showPlan = false;
  // Captured in initState: ref must not be used from dispose().
  late final Speech _speech;

  @override
  void initState() {
    super.initState();
    _speech = ref.read(speechProvider);
    HapticFeedback.heavyImpact();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    unawaited(_speech.stop());
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
    unawaited(_stopReading());
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
          ? AppLocalizations.of(context).checkInSent(status.label(AppLocalizations.of(context)))
          : AppLocalizations.of(context).checkInQueued),
      backgroundColor: result == CheckInResult.sent
          ? HazardColors.normal : HazardColors.warning,
    ));
  }

  Future<void> _stopReading() async {
    await _speech.stop();
    if (mounted) setState(() => _reading = false);
  }

  Future<void> _toggleReading(String script, Locale locale) async {
    if (_reading) return _stopReading();
    setState(() => _reading = true);
    await _speech.speak(script, locale);
    if (mounted) setState(() => _reading = false);
  }

  Future<void> _call112() async {
    try {
      if (await launchUrl(Uri(scheme: 'tel', path: '112'))) return;
    } catch (_) {
      // No dialer is available.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).dial112)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(incidentControllerProvider);
    final incident = _find(state);
    if (incident == null || incident.isClosed) {
      return _AllClear(onClose: () => Navigator.of(context).maybePop());
    }
    final labels = ref.watch(zoneLabelsProvider).valueOrNull;
    final zoneName = labels?[incident.primaryZoneId]?.trim();
    final routeState = ref.watch(evacuationProvider);
    final info = routeState.valueOrNull;
    final choice = info == null
        ? null
        : selectRoute(
            info,
            hazardZoneIds: incident.hazardZoneIds,
            userZoneId: null,
          );
    final assemblyPointName = choice == null
        ? null
        : info?.assemblyById(choice.route.toAssemblyPointId)?.label ??
            (choice.route.waypoints.isEmpty
                ? null
                : choice.route.waypoints.last.label);
    final readAloudScript = buildEvacuationScript(
      l10n: l10n,
      hazardDont: hazardDont(l10n, incident.hazardType),
      waypoints: choice?.route.waypoints ?? const [],
      avoidZoneName: zoneName,
      assemblyPointName: assemblyPointName,
      safety: choice?.safety,
    );

    return Scaffold(
      backgroundColor: HazardColors.surface,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: Container(
            color: HazardColors.forState(incident.state),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Wrap, not Row: at large text sizes Minimize drops to its own line
              // instead of squeezing the connection chip into a narrow column.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: HazardColors.onHazard),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: _ConnectionChip(
                    connected: state.connected,
                    lastMessageAt: state.lastMessageAt,
                    hasRoute: choice?.route.waypoints.isNotEmpty == true,
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    unawaited(_stopReading());
                    Navigator.of(context).maybePop();
                  },
                  icon: const Icon(Icons.expand_more),
                  label: Text(l10n.minimize),
                  style: TextButton.styleFrom(
                    foregroundColor: HazardColors.onHazard,
                    minimumSize: const Size(48, 48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 12),
              Text(incident.isEvacuation ? l10n.evacuateNow
                    : incident.hazardLabel(l10n).toUpperCase(),
                style: const TextStyle(color: HazardColors.onHazard,
                  fontSize: 32, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(zoneName == null || zoneName.isEmpty ? incident.hazardLabel(l10n)
                    : '${incident.hazardLabel(l10n)} · $zoneName',
                style: const TextStyle(color: HazardColors.onHazard, fontSize: 18)),
            ]),
          )),
          SliverToBoxAdapter(child: Container(
            color: HazardColors.warnBg,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.warning_amber_rounded, color: HazardColors.warnFg),
              const SizedBox(width: 10),
              Expanded(child: Text(hazardDont(l10n, incident.hazardType),
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
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_rounded, color: HazardColors.alarm),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          l10n.routeCrossesHazard,
                          style: const TextStyle(color: HazardColors.text,
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
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: HazardColors.warnFg),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          l10n.routeSafetyUnknown,
                          style: const TextStyle(color: HazardColors.warnFg,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                      ]),
                  ),
                  const SizedBox(height: 20),
                ],
                if (info?.savedAt case final DateTime savedAt) ...[
                  _SavedRouteNotice(savedAt: savedAt),
                  const SizedBox(height: 16),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n.evacuationRoute,
                      style: const TextStyle(
                        color: HazardColors.text,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _toggleReading(
                        readAloudScript,
                        Localizations.localeOf(context),
                      ),
                      icon: Icon(_reading ? Icons.stop : Icons.volume_up),
                      label: Text(_reading ? l10n.stopReading : l10n.readAloud),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: HazardColors.text,
                        side: const BorderSide(color: HazardColors.routeLine),
                        minimumSize: const Size(48, 48),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                routeState.when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (_, __) => const _StaticFallback(),
                  data: (_) => choice == null || choice.route.waypoints.isEmpty
                    ? const _StaticFallback()
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // Optional schematic above the route line; the step list
                        // below always stays visible.
                        OutlinedButton.icon(
                          onPressed: () => setState(() => _showPlan = !_showPlan),
                          icon: Icon(_showPlan ? Icons.map_outlined : Icons.map),
                          label: Text(_showPlan ? l10n.hideFloorPlan : l10n.seeFloorPlan),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: HazardColors.text,
                            side: const BorderSide(color: HazardColors.divider),
                            minimumSize: const Size(48, 48),
                            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (_showPlan) ...[
                          const SizedBox(height: 12),
                          FloorPlanSchematic(
                            layout: buildFloorPlanLayout(
                              ref.watch(zonesProvider).valueOrNull ?? const [],
                              choice.route.waypoints,
                              incident.hazardZoneIds,
                            ),
                            startLabel: l10n.startHere,
                            notToScaleLabel: l10n.floorPlanNotToScale,
                            assemblyLabel: l10n.assemblyPoint,
                            semanticsLabel: l10n.floorPlanSemantics(
                              choice.route.waypoints.first.label,
                              assemblyPointName ?? l10n.assemblyPoint,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        RouteLine(waypoints: choice.route.waypoints,
                          avoidZoneName: zoneName),
                      ]),
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
    final l10n = AppLocalizations.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.map, color: HazardColors.muted),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.fallbackLeave,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(l10n.fallbackAssembly,
            style: const TextStyle(fontSize: 16)),
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
    final l10n = AppLocalizations.of(context);
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
              Expanded(child: Text(l10n.checkedIn(checkedInAs!.label(l10n)),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              TextButton(onPressed: submitting ? null : onChange,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48),
                  textStyle: const TextStyle(fontSize: 16)),
                child: Text(l10n.change)),
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
                label: Text(l10n.outAndSafe)),
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
                  icon: const Icon(Icons.sos), label: Text(l10n.needsHelp));
                final call = OutlinedButton.icon(
                  onPressed: onCall,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: HazardColors.text,
                    minimumSize: const Size.fromHeight(48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  icon: const Icon(Icons.phone), label: Text(l10n.call112));
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
                label: Text(l10n.safeStillInside)),
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
              Text(AppLocalizations.of(context).allClear, style: const TextStyle(color: HazardColors.onHazard, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(AppLocalizations.of(context).hazardCleared, style: const TextStyle(color: HazardColors.onHazardMuted)),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: HazardColors.surface, foregroundColor: HazardColors.normal),
                onPressed: onClose,
                child: Text(AppLocalizations.of(context).returnLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionChip extends StatefulWidget {
  const _ConnectionChip({
    required this.connected,
    required this.lastMessageAt,
    required this.hasRoute,
  });

  final bool connected;
  final DateTime? lastMessageAt;
  final bool hasRoute;

  @override
  State<_ConnectionChip> createState() => _ConnectionChipState();
}

class _ConnectionChipState extends State<_ConnectionChip> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.connected) {
      final offlineText = widget.hasRoute
          ? AppLocalizations.of(context).offlineSavedRoute
          : AppLocalizations.of(context).offlineNoRoute;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.wifi_off, color: HazardColors.onHazard, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text(offlineText, style: const TextStyle(color: HazardColors.onHazard,
            fontSize: 14, fontWeight: FontWeight.bold))),
      ]);
    }
    final text = liveConnectionLabel(AppLocalizations.of(context), lastMessageAt: widget.lastMessageAt, now: DateTime.now());
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(widget.connected ? Icons.wifi : Icons.wifi_off,
          color: HazardColors.onHazard, size: 18),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: const TextStyle(color: HazardColors.onHazard,
          fontSize: 14, fontWeight: FontWeight.bold))),
    ]);
  }
}

class _SavedRouteNotice extends StatelessWidget {
  const _SavedRouteNotice({required this.savedAt});

  final DateTime savedAt;

  @override
  Widget build(BuildContext context) {
    final localSavedAt = savedAt.toLocal();
    final time = DateFormat('HH:mm', Localizations.localeOf(context).toLanguageTag())
        .format(localSavedAt);
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HazardColors.warnBg,
        border: Border.all(color: HazardColors.warning),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.history, color: HazardColors.warnFg),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            l10n.savedRoute(time),
            style: const TextStyle(
              color: HazardColors.warnFg,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ]),
    );
  }
}
