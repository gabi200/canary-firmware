import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../i18n.dart';
import '../logic/hazard_advice.dart';
import '../logic/escape_plan.dart';
import '../logic/relative_location.dart';
import '../logic/route_selection.dart';
import '../models/check_in.dart';
import '../models/evacuation.dart';
import '../models/incident.dart';
import '../models/zone_info.dart';
import '../state/dashboard_providers.dart';
import '../state/incident_controller.dart';
import '../state/location_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'widgets/floor_plan_sketch.dart';
import 'widgets/household_checkin.dart';
import 'widgets/one_line_label.dart';
import 'widgets/route_line.dart';
import 'widgets/safety_sign.dart';
import 'widgets/where_now_card.dart';

class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key, required this.incidentId});
  final String incidentId;

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen> {
  CheckInStatus? _checkedInAs;
  bool _submitting = false;
  bool _answering = false;

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
    // Out and safe is also the answer to "Unde ești acum?".
    final where = residentLocationProvider(widget.incidentId);
    if (status == CheckInStatus.safeOutside && ref.read(where) != ResidentLocation.outside) {
      ref.read(where.notifier).answer(ResidentLocation.outside);
    }
    final result = await ref
        .read(incidentControllerProvider.notifier)
        .submitCheckIn(widget.incidentId, status);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _checkedInAs = status;
    });
    final l10n = context.l10n;
    _snack(result == CheckInResult.sent
        ? l10n.checkInSent(l10n.checkInLabel(status))
        : l10n.checkInQueued, ok: result == CheckInResult.sent);
  }

  /// Green when it reached the hub, amber (dark text) when it didn't.
  void _snack(String text, {required bool ok}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text, style: ok ? null : const TextStyle(color: HazardColors.warnFg)),
      backgroundColor: ok ? HazardColors.normal : HazardColors.warning,
    ));
  }

  /// "Unde ești acum?": remembered and sent to the hub. Outside also checks the
  /// resident in as out and safe, so they count as accounted for.
  Future<void> _answerWhere(ResidentLocation where) async {
    if (_answering) return;
    setState(() => _answering = true);
    final sent = await ref.read(residentLocationProvider(widget.incidentId).notifier).answer(where);
    if (!mounted) return;
    setState(() => _answering = false);
    if (where == ResidentLocation.outside && _checkedInAs != CheckInStatus.safeOutside) {
      await _checkIn(CheckInStatus.safeOutside); // its snackbar says what was sent
      return;
    }
    final l10n = context.l10n;
    _snack(sent ? l10n.whereSent(l10n.whereNowLabel(where)) : l10n.whereNotSent, ok: sent);
  }

  Future<void> _call112() async {
    try {
      if (await launchUrl(Uri(scheme: 'tel', path: '112'))) return;
    } catch (_) {
      // No dialer is available.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.dial112)),
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
    final l10n = context.l10n;
    final palette = context.palette;
    final hazard = l10n.hazardName(incident.hazardType);
    // Where the danger is for this resident, starting from their own home.
    final zones = ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[];
    final home = ref.watch(residentHomeProvider);
    final routeState = ref.watch(evacuationProvider);
    final info = routeState.valueOrNull;
    // The way out from the resident's floor when the hub has one, clear of the
    // hazard when it can be.
    final floorZones = {for (final z in escapeFloorZones(incident, zones, home)) z.id};
    final fromFloor = info?.routes.where((r) => floorZones.contains(r.fromZoneId)).toList() ?? const [];
    final choice = info == null ? null : selectRoute(
      fromFloor.isEmpty ? info : EvacuationInfo(routes: fromFloor, assemblyPoints: info.assemblyPoints),
      hazardZoneIds: incident.hazardZoneIds, userZoneId: null);
    final where = hazardWhere(incident, {for (final z in zones) z.id: z}, home);
    final whereText = where.place == HazardPlace.unknown && zoneName != null && zoneName.isNotEmpty
        ? '$hazard · $zoneName'
        : l10n.hazardWhereText(where);
    final answer = ref.watch(residentLocationProvider(widget.incidentId));
    final assemblyPoint = (choice == null ? null : info?.assemblyById(choice.route.toAssemblyPointId)?.label) ??
        info?.assemblyPoints.firstOrNull?.label;

    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: Container(
            color: HazardColors.forState(incident.state),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
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
                    child: Text(state.connected ? l10n.live : l10n.offlineShowingSavedRoute,
                      style: const TextStyle(color: HazardColors.onHazard,
                        fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                )),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.expand_more),
                  label: Text(l10n.minimize),
                  style: TextButton.styleFrom(
                    foregroundColor: HazardColors.onHazard,
                    minimumSize: const Size(48, 48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ]),
              const SizedBox(height: 8),
              // Signs beside the title, so the question below stays in view.
              Row(children: [
                if (incident.isEvacuation) ...[
                  const SafetySignImage(SafetySign.e002, size: 48),
                  const SizedBox(width: 8),
                ],
                SafetySignImage(hazardSign(incident.hazardType), size: 48),
                const SizedBox(width: 12),
                Expanded(child: Text(incident.isEvacuation ? l10n.evacuateNow
                      : hazard.toUpperCase(),
                  style: const TextStyle(color: HazardColors.onHazard,
                    fontSize: 28, fontWeight: FontWeight.w900))),
              ]),
              const SizedBox(height: 10),
              Text(whereText,
                style: const TextStyle(color: HazardColors.onHazard,
                  fontSize: 19, fontWeight: FontWeight.w700)),
              if (home.title case final String mine) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.person_pin_circle, color: HazardColors.onHazard, size: 20),
                  const SizedBox(width: 6),
                  Expanded(child: Text(l10n.youAre(mine),
                    style: const TextStyle(color: HazardColors.onHazard,
                      fontSize: 15, fontWeight: FontWeight.w600))),
                ]),
              ],
            ]),
          )),
          SliverToBoxAdapter(child: Container(
            color: HazardColors.warnBg,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              for (final sign in hazardAdviceSigns(incident.hazardType)) ...[
                SafetySignImage(sign, size: 40),
                const SizedBox(width: 8),
              ],
              const SizedBox(width: 2),
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
                WhereNowCard(
                  answer: answer,
                  busy: _answering,
                  advice: answer == null ? null : l10n.whereAdviceText(
                    whereAdvice(answer, where.place, evacuation: incident.isEvacuation),
                    assemblyPoint: assemblyPoint),
                  onAnswer: _answerWhere,
                ),
                if (zones.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(l10n.dangerPlanTitle,
                    style: TextStyle(color: palette.text,
                      fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  IncidentPlan(incident: incident, zones: zones, home: home, route: choice?.route),
                ],
                const SizedBox(height: 24),
                if (choice?.crossesHazard ?? false) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: HazardColors.alarm, width: 2),
                      borderRadius: BorderRadius.circular(12)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SafetySignImage(SafetySign.w001, size: 28),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          l10n.routeCrossesHazard,
                          style: TextStyle(color: palette.text,
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
                        const SafetySignImage(SafetySign.w001, size: 28),
                        const SizedBox(width: 10),
                        Expanded(child: Text(
                          l10n.routeUnchecked,
                          style: const TextStyle(color: HazardColors.warnFg,
                            fontSize: 16, fontWeight: FontWeight.bold))),
                      ]),
                  ),
                  const SizedBox(height: 20),
                ],
                Text(l10n.evacuationRoute,
                  style: TextStyle(color: palette.text,
                    fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                routeState.when(
                  // A language switch refetches: keep the route on screen meanwhile.
                  skipLoadingOnReload: true,
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (_, __) => const _StaticFallback(),
                  data: (_) => choice == null || choice.route.waypoints.isEmpty
                    ? const _StaticFallback()
                    : RouteLine(waypoints: [
                        // Start from the resident's own apartment.
                        if (home.title case final String mine)
                          Waypoint(id: 'home', label: l10n.youAre(mine), kind: 'home'),
                        ...choice.route.waypoints,
                      ], avoidZoneName: zoneName),
                ),
                // Household members (emergency profiles): below the route until
                // the resident has checked in, then in the bottom bar.
                if (_checkedInAs == null) ...[
                  const SizedBox(height: 8),
                  HouseholdCheckIn(incidentId: widget.incidentId),
                ],
              ],
            )),
          ),
        ]),
      ),
      bottomNavigationBar: _CheckInBar(
        submitting: _submitting,
        checkedInAs: _checkedInAs,
        household: HouseholdCheckIn(incidentId: widget.incidentId),
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
    final l10n = context.l10n;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SafetySignImage(SafetySign.e002, size: 32),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.useNearestExit,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(l10n.useNearestExitDetail,
            style: const TextStyle(fontSize: 16)),
        ])),
    ]);
  }
}

class _CheckInBar extends StatelessWidget {
  const _CheckInBar({required this.submitting, required this.checkedInAs,
    required this.household,
    required this.onCheckIn, required this.onChange, required this.onCall});
  final bool submitting;
  final CheckInStatus? checkedInAs;

  /// "Who else is at home?", shown here once the resident has checked in.
  final Widget household;
  final void Function(CheckInStatus) onCheckIn;
  final VoidCallback onChange;
  final VoidCallback onCall;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return SafeArea(top: false, child: Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.48),
      decoration: BoxDecoration(color: palette.surface,
        border: Border(top: BorderSide(color: palette.divider))),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: checkedInAs != null
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(Icons.check_circle, color: palette.ink(HazardColors.normal)),
                const SizedBox(width: 8),
                Expanded(child: Text(l10n.checkedIn(l10n.checkInLabel(checkedInAs!)),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                TextButton(onPressed: submitting ? null : onChange,
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48),
                    textStyle: const TextStyle(fontSize: 16)),
                  child: Text(l10n.change)),
              ]),
              household,
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FilledButton.icon(
                onPressed: submitting ? null : () => onCheckIn(CheckInStatus.safeOutside),
                style: FilledButton.styleFrom(
                  backgroundColor: HazardColors.normal,
                  foregroundColor: HazardColors.onHazard,
                  minimumSize: const Size.fromHeight(56),
                  textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                icon: const SafetySignImage(SafetySign.e007, size: 28, decorative: true),
                label: OneLineLabel(l10n.imOutAndSafe)),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, constraints) {
                // Side by side only if both labels fit on one line at this
                // width and text size; otherwise full-width, stacked.
                const style = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);
                final narrow = !labelsFit(context, [l10n.iNeedHelp, l10n.call112], style,
                  (constraints.maxWidth - 8) / 2);
                final help = FilledButton.icon(
                  onPressed: submitting ? null : () => onCheckIn(CheckInStatus.needsHelp),
                  style: FilledButton.styleFrom(
                    backgroundColor: HazardColors.alarm,
                    foregroundColor: HazardColors.onHazard,
                    minimumSize: const Size.fromHeight(48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  icon: const Icon(Icons.sos), label: OneLineLabel(l10n.iNeedHelp));
                final call = OutlinedButton.icon(
                  onPressed: onCall,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.text,
                    minimumSize: const Size.fromHeight(48),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  icon: const SafetySignImage(SafetySign.e004, size: 24, decorative: true),
                  label: OneLineLabel(l10n.call112));
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
                  foregroundColor: palette.text,
                  minimumSize: const Size.fromHeight(48),
                  textStyle: const TextStyle(fontSize: 16)),
                icon: const Icon(Icons.home_outlined),
                label: OneLineLabel(l10n.imSafeStillInside)),
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
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: HazardColors.normal,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.verified_user, color: HazardColors.onHazard, size: 96),
              const SizedBox(height: 16),
              Text(l10n.allClear, style: const TextStyle(color: HazardColors.onHazard, fontSize: 28, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(l10n.hazardCleared, style: const TextStyle(color: HazardColors.onHazardMuted)),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: HazardColors.surface, foregroundColor: HazardColors.normal),
                onPressed: onClose,
                child: Text(l10n.returnAction),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
