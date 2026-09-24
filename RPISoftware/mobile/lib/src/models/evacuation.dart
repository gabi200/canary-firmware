class AssemblyPoint {
  const AssemblyPoint({required this.id, required this.label, this.lat, this.lon});
  final String id;
  final String label;
  final double? lat;
  final double? lon;

  factory AssemblyPoint.fromJson(Map<String, dynamic> j) => AssemblyPoint(
        id: j['id'] as String,
        label: (j['label'] ?? '') as String,
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
      );
}

class EvacuationRoute {
  const EvacuationRoute({
    required this.id,
    required this.label,
    required this.path,
    required this.toAssemblyPointId,
    this.fromZoneId,
  });

  final String id;
  final String label;
  final List<String> path;
  final String toAssemblyPointId;
  final String? fromZoneId;

  factory EvacuationRoute.fromJson(Map<String, dynamic> j) => EvacuationRoute(
        id: j['id'] as String,
        label: (j['label'] ?? '') as String,
        path: ((j['path'] ?? []) as List).map((e) => e.toString()).toList(),
        toAssemblyPointId: j['to_assembly_point_id'] as String,
        fromZoneId: j['from_zone_id'] as String?,
      );
}

class EvacuationInfo {
  const EvacuationInfo({required this.routes, required this.assemblyPoints});
  final List<EvacuationRoute> routes;
  final List<AssemblyPoint> assemblyPoints;

  factory EvacuationInfo.fromJson(Map<String, dynamic> j) => EvacuationInfo(
        routes: ((j['routes'] ?? []) as List)
            .map((e) => EvacuationRoute.fromJson(e as Map<String, dynamic>))
            .toList(),
        assemblyPoints: ((j['assembly_points'] ?? []) as List)
            .map((e) => AssemblyPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  AssemblyPoint? assemblyById(String id) {
    for (final p in assemblyPoints) {
      if (p.id == id) return p;
    }
    return null;
  }
}
