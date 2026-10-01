class AssemblyPoint {
  const AssemblyPoint({
    required this.id,
    required this.label,
    this.lat,
    this.lon,
  });
  final String id;
  final String label;
  final double? lat;
  final double? lon;

  factory AssemblyPoint.fromJson(Map<String, dynamic> j) => AssemblyPoint(
    id: j['id'] as String,
    label: j['label'] is String ? j['label'] as String : '',
    lat: j['lat'] is num ? (j['lat'] as num).toDouble() : null,
    lon: j['lon'] is num ? (j['lon'] as num).toDouble() : null,
  );
}

class Waypoint {
  const Waypoint({
    required this.id,
    required this.label,
    this.kind = 'waypoint',
    this.hint = '',
  });

  final String id;
  final String label;
  final String kind;
  final String hint;

  factory Waypoint.fromJson(Map<String, dynamic> j) => Waypoint(
    id: j['id'] as String,
    label: j['label'] is String ? j['label'] as String : j['id'] as String,
    kind: j['kind'] is String ? j['kind'] as String : 'waypoint',
    hint: j['hint'] is String ? j['hint'] as String : '',
  );
}

class EvacuationRoute {
  const EvacuationRoute({
    required this.id,
    required this.label,
    required this.path,
    required this.toAssemblyPointId,
    this.fromZoneId,
    this.waypoints = const [],
  });

  final String id;
  final String label;
  final List<String> path;
  final String toAssemblyPointId;
  final String? fromZoneId;
  final List<Waypoint> waypoints;

  factory EvacuationRoute.fromJson(
    Map<String, dynamic> j, {
    String? assemblyPointLabel,
  }) {
    final rawPath = j['path'];
    final path = rawPath is List
        ? [for (final entry in rawPath) if (_pathId(entry) case final String id) id]
        : <String>[];
    final providedWaypoints = j['waypoints'] is List ? j['waypoints'] as List : const [];
    final waypoints = providedWaypoints.isNotEmpty
        ? providedWaypoints
              .whereType<Map<String, dynamic>>()
              .where((e) => e['id'] is String)
              .map(Waypoint.fromJson)
              .toList()
        : [
            for (var i = 0; i < path.length; i++)
              Waypoint(
                id: path[i],
                label: i == path.length - 1 && assemblyPointLabel != null
                    ? assemblyPointLabel
                    : _humanizeId(path[i]),
              ),
          ];
    return EvacuationRoute(
      id: j['id'] as String,
      label: j['label'] is String ? j['label'] as String : '',
      path: path,
      toAssemblyPointId: j['to_assembly_point_id'] as String,
      fromZoneId: j['from_zone_id'] is String ? j['from_zone_id'] as String : null,
      waypoints: waypoints,
    );
  }

  static String? _pathId(dynamic entry) {
    if (entry is String) return entry;
    if (entry is Map && entry['id'] is String) return entry['id'] as String;
    return null;
  }

  static String _humanizeId(String id) {
    final words = id.replaceAll('_', ' ').trim().toLowerCase();
    if (words.isEmpty) return id;
    return words[0].toUpperCase() + words.substring(1);
  }
}

class EvacuationInfo {
  const EvacuationInfo({
    required this.routes,
    required this.assemblyPoints,
    this.savedAt,
  });
  final List<EvacuationRoute> routes;
  final List<AssemblyPoint> assemblyPoints;
  /// Null for a route fetched from the hub; non-null for an offline saved route.
  final DateTime? savedAt;

  factory EvacuationInfo.fromJson(Map<String, dynamic> j) {
    final rawAssemblyPoints = j['assembly_points'];
    final assemblyPoints = (rawAssemblyPoints is List ? rawAssemblyPoints : const [])
        .whereType<Map<String, dynamic>>()
        .where((e) => e['id'] is String)
        .map(AssemblyPoint.fromJson)
        .toList();
    final rawRoutes = j['routes'];
    return EvacuationInfo(
      routes: (rawRoutes is List ? rawRoutes : const [])
          .whereType<Map<String, dynamic>>()
          .where((route) => route['id'] is String && route['to_assembly_point_id'] is String)
          .map((route) {
        return EvacuationRoute.fromJson(
          route,
          assemblyPointLabel: _assemblyLabelFor(
            route['to_assembly_point_id'] as String,
            assemblyPoints,
          ),
        );
      }).toList(),
      assemblyPoints: assemblyPoints,
    );
  }

  static String? _assemblyLabelFor(String id, List<AssemblyPoint> points) {
    for (final point in points) {
      if (point.id == id) return point.label;
    }
    return null;
  }

  AssemblyPoint? assemblyById(String id) {
    for (final p in assemblyPoints) {
      if (p.id == id) return p;
    }
    return null;
  }
}
