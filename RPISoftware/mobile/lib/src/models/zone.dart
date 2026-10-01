class ZoneInfo {
  const ZoneInfo({
    required this.id,
    required this.floorId,
    required this.unitId,
    required this.label,
    required this.kind,
    required this.x,
    required this.y,
  });

  final String id;
  final String floorId;
  final String? unitId;
  final String label;
  final String kind;
  final double x;
  final double y;

  factory ZoneInfo.fromJson(Map<String, dynamic> json) {
    double coordinate(Object? value) {
      final parsed = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
      return parsed != null && parsed.isFinite ? parsed : 0;
    }

    final id = json['id'] is String ? json['id'] as String : '';
    return ZoneInfo(
      id: id,
      floorId: json['floor_id'] is String ? json['floor_id'] as String : '',
      unitId: json['unit_id'] is String ? json['unit_id'] as String : null,
      label: json['label'] is String && (json['label'] as String).isNotEmpty
          ? json['label'] as String
          : id,
      kind: json['kind'] is String ? json['kind'] as String : '',
      x: coordinate(json['pos_x']),
      y: coordinate(json['pos_y']),
    );
  }
}
