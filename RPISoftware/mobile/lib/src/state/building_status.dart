import '../models/incident.dart';
import 'incident_controller.dart';
import 'summary_controller.dart';

/// What the top of the home / dashboard says, from the live incidents and the
/// hub summary together, so the two never contradict each other.
enum BuildingStatusKind {
  /// An alarming incident (alarm / escalation / evacuation): the alarm screen.
  alarm,

  /// An open incident still being detected / verified: calm amber card, no alarm.
  verifying,

  /// No incident, but the hub reports danger / needs attention.
  danger,
  attention,

  /// Sensors haven't reported, or the hub can't be reached.
  unknown,
  loading,

  /// No open incident and the hub says all is ok.
  clear,
}

class BuildingStatus {
  const BuildingStatus(this.kind, {this.incident, this.headline, this.unreachable = false});
  final BuildingStatusKind kind;
  final Incident? incident;

  /// The hub's headline (already in the app language), when it has one.
  final String? headline;

  /// [BuildingStatusKind.unknown] because the summary couldn't be fetched.
  final bool unreachable;

  /// Pill state for [StatusPill]: an incident state or a hub level.
  String get pillState => switch (kind) {
        BuildingStatusKind.alarm || BuildingStatusKind.verifying => incident!.state,
        BuildingStatusKind.danger => 'danger',
        BuildingStatusKind.attention => 'attention',
        BuildingStatusKind.unknown || BuildingStatusKind.loading => 'unknown',
        BuildingStatusKind.clear => 'normal',
      };
}

BuildingStatus buildingStatusOf(IncidentsState incidents, SummaryState summary) {
  final alarm = incidents.activeAlarm;
  if (alarm != null) return BuildingStatus(BuildingStatusKind.alarm, incident: alarm);
  for (final i in incidents.incidents) {
    if (!i.isClosed) return BuildingStatus(BuildingStatusKind.verifying, incident: i);
  }
  final s = summary.summary;
  if (s == null) {
    return summary.error == null
        ? const BuildingStatus(BuildingStatusKind.loading)
        : const BuildingStatus(BuildingStatusKind.unknown, unreachable: true);
  }
  final headline = s.headline.isEmpty ? null : s.headline;
  return switch (s.status) {
    'danger' => BuildingStatus(BuildingStatusKind.danger, headline: headline),
    'attention' => BuildingStatus(BuildingStatusKind.attention, headline: headline),
    // The hub may know of an incident the list hasn't caught up with yet.
    'ok' when s.activeIncidents > 0 => BuildingStatus(BuildingStatusKind.attention, headline: headline),
    'ok' => const BuildingStatus(BuildingStatusKind.clear),
    _ => BuildingStatus(BuildingStatusKind.unknown, headline: headline),
  };
}
