/// `GET /api/v1/nodes/{node_id}/history`: a node's measurements over a window,
/// oldest first, time-bucket aggregated by the hub (≤ 360 points). A null value
/// means the sensor was warming up, faulty or invalid at that time: it is drawn
/// as a gap, never as 0.
class HistoryPoint {
  const HistoryPoint({required this.ts, required this.values});

  final DateTime ts;
  final Map<String, double?> values;

  double? operator [](String field) => values[field];

  static HistoryPoint? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final ts = raw['ts'] is String ? DateTime.tryParse(raw['ts'] as String) : null;
    if (ts == null) return null;
    final values = <String, double?>{};
    final rawValues = raw['values'];
    if (rawValues is Map<String, dynamic>) {
      for (final MapEntry(:key, :value) in rawValues.entries) {
        values[key] = value is num && value.isFinite ? value.toDouble() : null;
      }
    }
    return HistoryPoint(ts: ts, values: values);
  }
}

class NodeHistory {
  const NodeHistory({
    required this.nodeId,
    required this.minutes,
    required this.points,
    required this.end,
  });

  final String nodeId;

  /// Window length; the window is [start, end].
  final int minutes;
  final List<HistoryPoint> points;

  /// Window end: the fetch time, or the newest point if the hub's clock is ahead.
  final DateTime end;
  DateTime get start => end.subtract(Duration(minutes: minutes));

  factory NodeHistory.fromJson(Map<String, dynamic> j, {DateTime? now}) {
    final raw = j['points'];
    final points = [
      if (raw is List)
        for (final p in raw)
          if (HistoryPoint.tryParse(p) case final HistoryPoint point) point,
    ]..sort((a, b) => a.ts.compareTo(b.ts));
    final fetched = (now ?? DateTime.now()).toUtc();
    final newest = points.isEmpty ? null : points.last.ts.toUtc();
    return NodeHistory(
      nodeId: j['node_id'] is String ? j['node_id'] as String : '',
      minutes: j['minutes'] is num ? (j['minutes'] as num).toInt() : 60,
      points: points,
      end: newest != null && newest.isAfter(fetched) ? newest : fetched,
    );
  }
}
