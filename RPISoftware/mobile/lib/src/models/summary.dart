// Hub sensor analysis (docs/HARDWARE.md §3–4): building -> zones -> nodes ->
// indicators. Analysis only: the summary never carries raw measurements (no
// ppm, ADC, µg/m³, °C, %RH, RSSI) and the app never asks for them. Parsing is
// tolerant: missing or mistyped fields fall back to neutral defaults.

/// One analyzed signal of a node, e.g. air quality "Good" (detail "AQI 29").
class Indicator {
  const Indicator({
    required this.key,
    required this.label,
    required this.level,
    required this.value,
    this.detail,
    this.trend,
  });

  /// air_quality | co | gas | comfort | occupancy | leak | valve | health
  final String key;
  final String label;

  /// ok | attention | danger | unknown
  final String level;
  final String value;
  final String? detail;

  /// rising | falling | stable, or null
  final String? trend;

  factory Indicator.fromJson(Map<String, dynamic> j) => Indicator(
        key: _str(j['key']),
        label: _str(j['label']),
        level: _str(j['level'], 'unknown'),
        value: _str(j['value'], '—'),
        detail: _optStr(j['detail']),
        trend: _optStr(j['trend']),
      );
}

/// Analysis of one physical sensor (an ESP32 node).
class NodeAnalysis {
  const NodeAnalysis({
    required this.nodeId,
    required this.kind,
    required this.name,
    required this.online,
    required this.stale,
    required this.status,
    required this.headline,
    this.zoneId,
    this.lastSeenTs,
    this.advice = const [],
    this.indicators = const [],
  });

  final String nodeId;
  final String kind; // air | water
  final String name;
  final String? zoneId;
  final bool online;
  final bool stale;
  final DateTime? lastSeenTs;
  final String status; // ok | attention | danger
  final String headline;
  final List<String> advice;
  final List<Indicator> indicators;

  /// Reporting normally (online and not stale).
  bool get isLive => online && !stale;

  factory NodeAnalysis.fromJson(Map<String, dynamic> j) {
    final id = _str(j['node_id']);
    return NodeAnalysis(
      nodeId: id,
      kind: _str(j['kind']),
      name: _str(j['name'], id),
      zoneId: _optStr(j['zone_id']),
      online: j['online'] == true,
      stale: j['stale'] == true,
      lastSeenTs: _ts(j['last_seen_ts']),
      status: _str(j['status'], 'unknown'),
      headline: _str(j['headline']),
      advice: _strings(j['advice']),
      indicators: _maps(j['indicators']).map(Indicator.fromJson).toList(),
    );
  }
}

class ZoneSummary {
  const ZoneSummary({
    required this.zoneId,
    required this.zoneLabel,
    required this.status,
    required this.nodes,
    this.occupied,
  });

  final String zoneId;
  final String zoneLabel;
  final String status; // ok | attention | danger

  /// null when the zone has no air (presence) node.
  final bool? occupied;
  final List<NodeAnalysis> nodes;

  factory ZoneSummary.fromJson(Map<String, dynamic> j) => ZoneSummary(
        zoneId: _str(j['zone_id']),
        zoneLabel: _str(j['zone_label']),
        status: _str(j['status'], 'unknown'),
        occupied: j['occupied'] is bool ? j['occupied'] as bool : null,
        nodes: _maps(j['nodes']).map(NodeAnalysis.fromJson).toList(),
      );
}

/// `GET /api/v1/buildings/{id}/summary`.
class BuildingSummary {
  const BuildingSummary({
    required this.buildingId,
    required this.buildingName,
    required this.status,
    required this.headline,
    required this.nodesTotal,
    required this.nodesOnline,
    required this.activeIncidents,
    required this.zones,
    this.generatedTs,
  });

  final String buildingId;
  final String buildingName;
  final DateTime? generatedTs;
  final String status; // ok | attention | danger
  final String headline;
  final int nodesTotal;
  final int nodesOnline;
  final int activeIncidents;
  final List<ZoneSummary> zones;

  bool get hasNodes => zones.any((z) => z.nodes.isNotEmpty);

  NodeAnalysis? node(String nodeId) {
    for (final z in zones) {
      for (final n in z.nodes) {
        if (n.nodeId == nodeId) return n;
      }
    }
    return null;
  }

  factory BuildingSummary.fromJson(Map<String, dynamic> j) {
    final buildingId = _str(j['building_id']);
    final buildingName = _str(j['building_name']).trim();
    final zones = _maps(j['zones']).map(ZoneSummary.fromJson).toList();
    final nodes = [for (final z in zones) ...z.nodes];
    return BuildingSummary(
      buildingId: buildingId,
      buildingName: buildingName.isEmpty ? buildingId : buildingName,
      generatedTs: _ts(j['generated_ts']),
      status: _str(j['status'], 'unknown'),
      headline: _str(j['headline']),
      // Counts fall back to what the zones actually list.
      nodesTotal: _int(j['nodes_total']) ?? nodes.length,
      nodesOnline: _int(j['nodes_online']) ?? nodes.where((n) => n.online).length,
      activeIncidents: _int(j['active_incidents']) ?? 0,
      zones: zones,
    );
  }
}

String _str(Object? v, [String fallback = '']) => v is String && v.isNotEmpty ? v : fallback;

String? _optStr(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

DateTime? _ts(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String> _strings(Object? v) =>
    v is List ? v.whereType<String>().where((s) => s.isNotEmpty).toList() : const [];

Iterable<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? v.whereType<Map<String, dynamic>>() : const [];
