import 'dart:math' as math;

import 'sensor_series.dart';

/// Now / min / mean / max of a window; nulls (warming up, faults) ignored.
class SeriesStats {
  const SeriesStats({this.now, this.min, this.mean, this.max});
  final double? now;
  final double? min;
  final double? mean;
  final double? max;

  factory SeriesStats.of(Series s) {
    var n = 0;
    var sum = 0.0;
    double? lo;
    double? hi;
    for (final p in s.points) {
      final v = p.value;
      if (v == null) continue;
      n++;
      sum += v;
      lo = lo == null ? v : math.min(lo, v);
      hi = hi == null ? v : math.max(hi, v);
    }
    return SeriesStats(now: s.latest, min: lo, max: hi, mean: n == 0 ? null : sum / n);
  }
}

/// What the crosshair shows at [at]: the nearest reading in time. Inside a
/// gap (a null reading, or no reading within [maxGap] / 2 of [at]) the value
/// is null — "no data", never an interpolated or zero value.
SeriesPoint? readingAt(Series s, DateTime at, {required Duration maxGap}) {
  if (s.points.isEmpty) return null;
  SeriesPoint? best;
  var bestDiff = 0;
  for (final p in s.points) {
    final diff = (p.ts.difference(at).inMilliseconds).abs();
    if (best == null || diff < bestDiff) {
      best = p;
      bestDiff = diff;
    }
  }
  if (best == null) return null;
  if (bestDiff > maxGap.inMilliseconds / 2) return SeriesPoint(at, null);
  return best;
}

/// About [count] evenly spaced, "round" tick times across [start, end].
List<DateTime> timeTicks(DateTime start, DateTime end, {int count = 4}) {
  const steps = [
    Duration(minutes: 5), Duration(minutes: 10), Duration(minutes: 15), Duration(minutes: 30),
    Duration(hours: 1), Duration(hours: 2), Duration(hours: 3), Duration(hours: 6),
    Duration(hours: 12), Duration(days: 1), Duration(days: 2),
  ];
  final span = end.difference(start);
  final step = steps.firstWhere((d) => span.inMilliseconds / d.inMilliseconds <= count, orElse: () => steps.last);
  final local = start.toLocal();
  // First tick: start rounded up to the step in local time (midnight-based).
  final midnight = DateTime(local.year, local.month, local.day);
  final sinceMidnight = local.difference(midnight).inMilliseconds;
  final first = midnight.add(Duration(milliseconds: (sinceMidnight / step.inMilliseconds).ceil() * step.inMilliseconds));
  return [for (var t = first; !t.isAfter(end.toLocal()); t = t.add(step)) t];
}

/// "Nice" value ticks (1, 2, 2.5, 5 × 10ⁿ) covering [min, max].
List<double> valueTicks(double min, double max, {int count = 4}) {
  if (!(max > min)) return [min];
  final raw = (max - min) / count;
  final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final step = [1.0, 2.0, 2.5, 5.0, 10.0].map((m) => m * magnitude).firstWhere((s) => s >= raw);
  final first = (min / step).ceil() * step;
  return [for (var v = first; v <= max + step * 1e-9; v += step) double.parse(v.toStringAsFixed(6))];
}
