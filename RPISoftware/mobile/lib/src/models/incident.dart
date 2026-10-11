import '../config.dart';

class Incident {
  const Incident({
    required this.id,
    required this.buildingId,
    required this.hazardType,
    required this.severity,
    required this.state,
    this.primaryZoneId,
    this.affectedZoneIds = const [],
    this.openedTs,
    this.updatedTs,
  });

  final String id;
  final String buildingId;
  final String hazardType;
  final String severity;
  final String state;
  final String? primaryZoneId;
  final List<String> affectedZoneIds;
  final DateTime? openedTs;
  final DateTime? updatedTs;

  bool get isAlarming => Config.alarmingStates.contains(state);
  bool get isEvacuation => state == 'evacuation';
  bool get isClosed => state == 'resolution' || state == 'false_alarm' || state == 'normal';
  Set<String> get hazardZoneIds => {
        if (primaryZoneId != null) primaryZoneId!,
        ...affectedZoneIds,
      };

  factory Incident.fromJson(Map<String, dynamic> j) => Incident(
        id: j['id'] as String,
        buildingId: j['building_id'] as String,
        hazardType: (j['hazard_type'] ?? '') as String,
        severity: (j['severity'] ?? 'warning') as String,
        state: (j['state'] ?? 'detection') as String,
        primaryZoneId: j['primary_zone_id'] as String?,
        affectedZoneIds: _zoneIds(j['affected_zone_ids']),
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
        affectedZoneIds: _zoneIds(j['affected_zone_ids']),
        updatedTs: _ts(j['ts']),
      );

  static DateTime? _ts(dynamic v) => v == null ? null : DateTime.tryParse(v as String);
  static List<String> _zoneIds(dynamic value) =>
      value is List ? value.whereType<String>().toList() : const [];
}
