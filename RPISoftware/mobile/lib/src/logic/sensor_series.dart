import 'dart:math' as math;

import '../models/history.dart';

/// Field names of `GET /nodes/{id}/history` the resident app reads. Raw values
/// that are not meaningful to residents (gas ADC, water probe ADC) are fetched
/// only to derive plain-language states and are never displayed.
abstract final class HistoryFields {
  static const temperature = 'climate.temperature_c';
  static const humidity = 'climate.humidity_percent';
  static const pm25 = 'particulate.pm2_5';
  static const pm10 = 'particulate.pm10';
  static const co = 'co.ppm';
  static const gasAdc = 'gas.adc';
  static const coWarn = 'co.warn_ppm';
  static const coDanger = 'co.danger_ppm';
  static const gasWarn = 'gas.warn_adc';
  static const pm25Warn = 'particulate.warn_pm2_5';
  static const pm25Danger = 'particulate.danger_pm2_5';
  static const pm10Warn = 'particulate.warn_pm10';
  static const pm10Danger = 'particulate.danger_pm10';
  static const leakLatched = 'leak_latched';
  static const waterAdc = 'sensor.adc';
  static const wetThreshold = 'sensor.wet_threshold';

  static const air = [
    temperature, humidity, pm25, pm10, co, gasAdc,
    coWarn, coDanger, gasWarn, pm25Warn, pm25Danger, pm10Warn, pm10Danger,
  ];
  static const water = [leakLatched, waterAdc, wetThreshold];
  static const climate = [temperature, humidity];
}

class SeriesPoint {
  const SeriesPoint(this.ts, this.value);
  final DateTime ts;

  /// null: no valid reading at [ts] (warming up / fault) — a gap.
  final double? value;
}

/// One field over a history window.
class Series {
  const Series(this.points, {required this.start, required this.end});

  /// [field] of [history], optionally transformed (e.g. gas ADC → % of warning).
  factory Series.of(NodeHistory history, String field, {double Function(double v)? map}) {
    return Series(
      [
        for (final p in history.points)
          SeriesPoint(p.ts, switch (p[field]) { final double v => map == null ? v : map(v), null => null }),
      ],
      start: history.start,
      end: history.end,
    );
  }

  final List<SeriesPoint> points;
  final DateTime start;
  final DateTime end;

  bool get isEmpty => points.isEmpty;

  /// The newest point's value; null when there are no points or the newest
  /// reading is invalid (see [warmingUp]).
  double? get latest => points.isEmpty ? null : points.last.value;

  /// There is data, but the newest reading is null: the sensor is still warming
  /// up (or faulty) — never shown as 0.
  bool get warmingUp => points.isNotEmpty && points.last.value == null;

  /// Smallest and largest valid value in the window; nulls are ignored.
  ({double min, double max})? get range {
    double? lo;
    double? hi;
    for (final p in points) {
      final v = p.value;
      if (v == null) continue;
      lo = lo == null ? v : math.min(lo, v);
      hi = hi == null ? v : math.max(hi, v);
    }
    return lo == null || hi == null ? null : (min: lo, max: hi);
  }

  /// Runs of consecutive valid points to draw as connected lines. A null value
  /// or a silence longer than [maxGap] between two points ends a run, so the
  /// chart shows a gap instead of bridging (or dropping to 0).
  List<List<SeriesPoint>> runs({required Duration maxGap}) {
    final runs = <List<SeriesPoint>>[];
    List<SeriesPoint>? current;
    DateTime? lastTs;
    for (final p in points) {
      if (p.value == null) {
        current = null;
      } else {
        final silent = lastTs != null && p.ts.difference(lastTs) > maxGap;
        if (current == null || silent) {
          current = [];
          runs.add(current);
        }
        current.add(p);
      }
      lastTs = p.ts;
    }
    return runs;
  }
}

/// Longest silence still drawn as a continuous line: a few reporting periods
/// (air every ~15 s, water every ~60 s) or a few hub buckets, whichever is longer.
Duration maxGapFor({required int minutes, required String kind}) {
  final sample = Duration(seconds: kind == 'water' ? 60 : 15) * 4;
  final bucket = Duration(seconds: (minutes * 60 / 120).round());
  return sample > bucket ? sample : bucket;
}

/// Newest valid value of [field] in the window (thresholds are device config).
double? lastValue(NodeHistory history, String field) {
  for (final p in history.points.reversed) {
    final v = p[field];
    if (v != null) return v;
  }
  return null;
}

/// The MQ-5 gas reading as a percentage of the device's warning threshold. The
/// raw ADC count is uncalibrated, so it is never shown as a concentration.
double gasPercent(double adc, double warnAdc) =>
    warnAdc <= 0 ? 0 : (adc / warnAdc * 100).clamp(0, 999).toDouble();

/// Whether the water probe reports a leak at [p]: the device's latched flag,
/// or the probe above its wet threshold. null when neither is known.
bool? isWet(HistoryPoint p) {
  final latched = p[HistoryFields.leakLatched];
  final adc = p[HistoryFields.waterAdc];
  final wet = p[HistoryFields.wetThreshold];
  final probeWet = adc != null && wet != null ? adc >= wet : null;
  if (latched == null) return probeWet;
  return latched > 0 || (probeWet ?? false);
}

/// How serious a reading is; drives color, always alongside a word.
enum Tone { ok, info, attention, danger }

/// Plain-language state of one reading (one word on the tile).
enum Verdict {
  good(Tone.ok),
  moderate(Tone.attention),
  poor(Tone.attention),
  danger(Tone.danger),
  safe(Tone.ok),
  elevated(Tone.attention),
  normal(Tone.ok),
  cool(Tone.info),
  comfortable(Tone.ok),
  warm(Tone.info),
  dryAir(Tone.info),
  humidityOk(Tone.ok),
  humid(Tone.info),
  dry(Tone.ok),
  leak(Tone.danger);

  const Verdict(this.tone);
  final Tone tone;
}

/// Gas level: under 60 % of the warning threshold is normal, up to 100 %
/// elevated, above it danger.
Verdict gasVerdict(double percent) => percent < 60
    ? Verdict.normal
    : percent <= 100
        ? Verdict.elevated
        : Verdict.danger;

/// Carbon monoxide against the device's thresholds (~50 / 100 ppm).
Verdict coVerdict(double ppm, {double? warn, double? danger}) {
  final w = warn ?? 50;
  final d = danger ?? 100;
  return ppm < w
      ? Verdict.safe
      : ppm < d
          ? Verdict.elevated
          : Verdict.danger;
}

/// Particles: "good" up to the usual clean-air band, then the device thresholds.
Verdict pmVerdict(double ugm3, {required double good, double? warn, double? danger, required double defaultWarn, required double defaultDanger}) {
  final w = warn ?? defaultWarn;
  final d = danger ?? defaultDanger;
  if (ugm3 <= math.min(good, w)) return Verdict.good;
  if (ugm3 <= w) return Verdict.moderate;
  if (ugm3 <= d) return Verdict.poor;
  return Verdict.danger;
}

Verdict pm25Verdict(double v, {double? warn, double? danger}) =>
    pmVerdict(v, good: 12, warn: warn, danger: danger, defaultWarn: 35, defaultDanger: 150);

Verdict pm10Verdict(double v, {double? warn, double? danger}) =>
    pmVerdict(v, good: 54, warn: warn, danger: danger, defaultWarn: 100, defaultDanger: 250);

/// Room feel (approximate: measured inside the warm particle sensor).
Verdict temperatureVerdict(double c) => c < 18
    ? Verdict.cool
    : c > 26
        ? Verdict.warm
        : Verdict.comfortable;

Verdict humidityVerdict(double percent) => percent < 30
    ? Verdict.dryAir
    : percent > 60
        ? Verdict.humid
        : Verdict.humidityOk;

/// Vertical bounds for a sparkline of [series]: always includes [threshold] (so
/// a calm low line reads as calm next to its warning line); [zeroBased] for
/// amounts that start at 0; at least [minSpan] tall so noise isn't magnified.
({double min, double max}) chartBounds(Series series,
    {double? threshold, bool zeroBased = true, double minSpan = 1}) {
  final r = series.range;
  var lo = r?.min ?? 0;
  var hi = r?.max ?? 1;
  if (threshold != null) {
    lo = math.min(lo, threshold);
    hi = math.max(hi, threshold);
  }
  if (zeroBased) lo = math.min(0, lo);
  if (hi - lo < minSpan) {
    final mid = (hi + lo) / 2;
    lo = mid - minSpan / 2;
    hi = mid + minSpan / 2;
    if (zeroBased && lo < 0) {
      hi -= lo;
      lo = 0;
    }
  }
  final pad = (hi - lo) * 0.08;
  return (min: zeroBased && lo == 0 ? 0 : lo - pad, max: hi + pad);
}
