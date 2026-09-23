import '../config.dart';

class Incident {
  const Incident({
    required this.id,
    required this.buildingId,
    required this.hazardType,
    required this.severity,
    required this.state,
    this.primaryZoneId,
    this.openedTs,
    this.updatedTs,
  });

  final String id;
  final String buildingId;
  final String hazardType;
  final String severity;
  final String state;
  final String? primaryZoneId;
  final DateTime? openedTs;
  final DateTime? updatedTs;

  bool get isAlarming => Config.alarmingStates.contains(state);
  bool get isEvacuation => state == 'evacuation';
  bool get isClosed => state == 'resolution' || state == 'false_alarm' || state == 'normal';

  String get hazardLabel {
    switch (hazardType) {
      case 'combustible_gas':
        return 'Gas leak';
      case 'co':
        return 'Carbon monoxide';
      case 'water_leak':
        return 'Water leak';
      default:
        return hazardType;
    }
  }

  factory Incident.fromJson(Map<String, dynamic> j) => Incident(
        id: j['id'] as String,
        buildingId: j['building_id'] as String,
        hazardType: (j['hazard_type'] ?? '') as String,
        severity: (j['severity'] ?? 'warning') as String,
        state: (j['state'] ?? 'detection') as String,
        primaryZoneId: j['primary_zone_id'] as String?,
        openedTs: _ts(j['opened_ts']),
        updatedTs: _ts(j['updated_ts']),
      );

  /// Build from a WebSocket "incident" event (a subset of fields).
  factory Incident.fromWsEvent(Map<String, dynamic> j) => Incident(
        id: j['incident_id'] as String,
        buildingId: j['building_id'] as String,
        hazardType: (j['hazard_type'] ?? '') as String,
        severity: (j['severity'] ?? 'warning') as String,
        state: (j['state'] ?? 'detection') as String,
        primaryZoneId: j['primary_zone_id'] as String?,
        updatedTs: _ts(j['ts']),
      );

  static DateTime? _ts(dynamic v) => v == null ? null : DateTime.tryParse(v as String);
}
