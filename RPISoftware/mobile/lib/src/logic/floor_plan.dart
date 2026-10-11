/// Lays rooms out on a grid for the home "sketch". Zones only have a centre
/// point (metres), so rooms become equal cells placed by relative position:
/// nearby coordinates share a row / column, the order of rows and columns
/// follows the coordinates, and two rooms never share a cell.
library;

typedef PlanPoint = ({String id, double x, double y});
typedef GridCell = ({int col, int row});

/// Groups sorted coordinates into levels no wider than [tolerance] metres, so
/// two values more than [tolerance] apart always land on different levels.
Map<double, int> _levels(Iterable<double> values, double tolerance) {
  final sorted = values.toSet().toList()..sort();
  final out = <double, int>{};
  var level = -1;
  double? levelStart;
  for (final v in sorted) {
    if (levelStart == null || v - levelStart > tolerance) {
      level++;
      levelStart = v;
    }
    out[v] = level;
  }
  return out;
}

/// Cell per room id. Collisions in a row push the later room (by x, then id)
/// to the next free column; empty columns are then removed.
Map<String, GridCell> gridLayout(List<PlanPoint> rooms, {double tolerance = 1.0}) {
  if (rooms.isEmpty) return const {};
  final rows = _levels(rooms.map((r) => r.y), tolerance);
  final cols = _levels(rooms.map((r) => r.x), tolerance);
  final ordered = [...rooms]..sort((a, b) {
      final byX = a.x.compareTo(b.x);
      return byX != 0 ? byX : a.id.compareTo(b.id);
    });
  final taken = <GridCell>{};
  final placed = <String, GridCell>{};
  for (final r in ordered) {
    final row = rows[r.y]!;
    var col = cols[r.x]!;
    while (taken.contains((col: col, row: row))) {
      col++;
    }
    taken.add((col: col, row: row));
    placed[r.id] = (col: col, row: row);
  }
  // Drop empty columns / rows, keeping order.
  final usedCols = (placed.values.map((c) => c.col).toSet().toList()..sort());
  final usedRows = (placed.values.map((c) => c.row).toSet().toList()..sort());
  return {
    for (final MapEntry(:key, :value) in placed.entries)
      key: (col: usedCols.indexOf(value.col), row: usedRows.indexOf(value.row)),
  };
}
