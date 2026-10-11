/// `GET /buildings/{id}/zones` item: a room / area with its centre point.
class ZoneInfo {
  const ZoneInfo({
    required this.id,
    required this.label,
    required this.unitId,
    this.unitLabel,
    this.floorId,
    this.floorLabel,
    this.kind,
    this.unitKind,
    this.posX,
    this.posY,
  });

  final String id;
  final String label;
  final String unitId;
  final String? unitLabel;
  final String? floorId;
  final String? floorLabel;

  /// Room kind (kitchen, bedroom, hallway, boiler, ...).
  final String? kind;

  /// residential | common, when the hub says.
  final String? unitKind;

  /// Centre point in metres; null when unknown.
  final double? posX;
  final double? posY;

  /// Shared area of the building (hallway, boiler room) rather than a home.
  bool get isCommon => unitKind == 'common' || unitId.toLowerCase().contains('common');

  bool get hasPosition => posX != null && posY != null;

  factory ZoneInfo.fromJson(Map<String, dynamic> j) {
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    double? num_(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    return ZoneInfo(
      id: j['id'] as String,
      label: str(j['label']) ?? j['id'] as String,
      unitId: str(j['unit_id']) ?? '',
      unitLabel: str(j['unit_label']),
      floorId: str(j['floor_id']),
      floorLabel: str(j['floor_label']),
      kind: str(j['kind']),
      unitKind: str(j['unit_kind']),
      posX: num_(j['pos_x']),
      posY: num_(j['pos_y']),
    );
  }
}
