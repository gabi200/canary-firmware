import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/models/check_in.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/incident_controller.dart';

const incidentId = 'incident-evacuation';
const hazardZoneId = 'zone-hazard';

Incident evacuationIncident({
  String hazardType = 'combustible_gas',
  String state = 'evacuation',
}) =>
    Incident(
      id: incidentId,
      buildingId: 'building-1',
      hazardType: hazardType,
      severity: 'critical',
      state: state,
      primaryZoneId: hazardZoneId,
    );

EvacuationInfo evacuationForSafety(String safety) {
  final path = switch (safety) {
    'crosses' => const ['zone-lobby', hazardZoneId, 'assembly-point'],
    'unknown' => const <String>[],
    _ => const ['zone-lobby', 'assembly-point'],
  };
  return EvacuationInfo(
    routes: [
      EvacuationRoute(
        id: 'route-1',
        label: 'Main exit',
        path: path,
        fromZoneId: 'zone-lobby',
        toAssemblyPointId: 'assembly-point',
        waypoints: const [
          Waypoint(id: 'zone-lobby', label: 'Lobby', hint: 'Leave by the main doors.'),
          Waypoint(id: 'assembly-point', label: 'Assembly point'),
        ],
      ),
    ],
    assemblyPoints: const [
      AssemblyPoint(id: 'assembly-point', label: 'Assembly point'),
    ],
  );
}

/// A real controller with its transport path disabled by a null session.
/// It records check-ins without issuing HTTP requests.
class FakeIncidentController extends IncidentController {
  FakeIncidentController({required Storage storage, required IncidentsState initialState})
      : super(ApiClient(), storage, null) {
    state = initialState;
  }

  final List<(String incidentId, CheckInStatus status)> submissions = [];

  @override
  Future<CheckInResult> submitCheckIn(String incidentId, CheckInStatus status) async {
    submissions.add((incidentId, status));
    return CheckInResult.sent;
  }
}
