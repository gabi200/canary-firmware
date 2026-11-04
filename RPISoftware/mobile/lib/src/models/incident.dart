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
    this.signature,
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
  final IncidentSignature? signature;

  bool get hasClassification => !isClosed && (signature?.isVisible ?? false);

  bool get isAlarming => Config.alarmingStates.contains(state);
  bool get isEvacuation => state == 'evacuation';
  bool get isClosed =>
      state == 'resolution' || state == 'false_alarm' || state == 'normal';
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
        signature: IncidentSignature.parse(j['signature']),
      );

  /// Build from a WebSocket "incident" event (a subset of fields).
  factory Incident.fromWsEvent(Map<String, dynamic> j, {Incident? previous}) =>
      Incident(
        id: j['incident_id'] as String,
        buildingId: j['building_id'] as String,
        hazardType: (j['hazard_type'] ?? '') as String,
        severity: (j['severity'] ?? 'warning') as String,
        state: (j['state'] ?? 'detection') as String,
        primaryZoneId: j['primary_zone_id'] as String?,
        affectedZoneIds: _zoneIds(j['affected_zone_ids']),
        updatedTs: _ts(j['ts']),
        openedTs: previous?.openedTs,
        signature: j.containsKey('signature')
            ? IncidentSignature.parse(j['signature'])
            : previous?.signature,
      );

  static DateTime? _ts(dynamic v) => v is String ? DateTime.tryParse(v) : null;
  static List<String> _zoneIds(dynamic value) =>
      value is List ? value.whereType<String>().toList() : const [];
}

class IncidentSignature {
  const IncidentSignature(
      {this.label,
      this.confidence,
      this.evidence = const [],
      this.shadowLabel,
      this.shadowConfidence,
      this.modelVersion,
      this.ts});

  final String? label;
  final double? confidence;
  final List<String> evidence;
  final String? shadowLabel;
  final double? shadowConfidence;
  final String? modelVersion;
  final DateTime? ts;

  static const visibleLabels = {
    'smouldering_fire',
    'flaming_fire',
    'gas_leak',
    'steam',
    'cooking',
    'aerosol',
  };
  bool get isVisible =>
      visibleLabels.contains(label) || visibleLabels.contains(shadowLabel);

  static IncidentSignature? parse(dynamic value) =>
      value is Map<String, dynamic> ? IncidentSignature.fromJson(value) : null;

  factory IncidentSignature.fromJson(Map<String, dynamic> j) =>
      IncidentSignature(
        label: j['label'] is String ? j['label'] as String : null,
        confidence: _confidence(j['confidence']),
        evidence: j['evidence'] is List
            ? (j['evidence'] as List).whereType<String>().toList()
            : const [],
        shadowLabel:
            j['shadow_label'] is String ? j['shadow_label'] as String : null,
        shadowConfidence: _confidence(j['shadow_confidence']),
        modelVersion:
            j['model_version'] is String ? j['model_version'] as String : null,
        ts: Incident._ts(j['ts']),
      );

  static double? _confidence(dynamic value) {
    if (value is! num || !value.isFinite || value < 0 || value > 1) return null;
    return value.toDouble();
  }
}
