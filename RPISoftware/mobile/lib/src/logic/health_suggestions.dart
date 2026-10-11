import 'dart:math' as math;

import '../models/care_profile.dart';

/// Raw values read from Apple Health (iOS only), as the Swift side sends them.
/// Never stored: it lives in the form's memory until the user saves (with
/// consent) the needs they chose.
class HealthReading {
  const HealthReading({
    this.available = true,
    this.wheelchairUse,
    this.walkingSteadiness,
    this.audiogram = const [],
  });

  /// HealthKit exists on this device.
  final bool available;

  /// 'yes' | 'no' | 'notSet', or null when unreadable.
  final String? wheelchairUse;

  /// Latest Apple walking steadiness as a fraction (0.35 = 35 %).
  final double? walkingSteadiness;

  /// Latest audiogram's points.
  final List<AudiogramPoint> audiogram;

  factory HealthReading.fromMap(Map<Object?, Object?> m) {
    double? num_(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final rawPoints = m['audiogram'];
    return HealthReading(
      available: m['available'] != false,
      wheelchairUse: m['wheelchairUse'] is String ? m['wheelchairUse'] as String : null,
      walkingSteadiness: num_(m['walkingSteadiness']),
      audiogram: [
        if (rawPoints is List)
          for (final p in rawPoints.whereType<Map<Object?, Object?>>())
            if (num_(p['hz']) case final double hz)
              AudiogramPoint(hz: hz, left: num_(p['left']), right: num_(p['right'])),
      ],
    );
  }
}

/// One audiogram frequency with the hearing threshold per ear, in dB HL.
class AudiogramPoint {
  const AudiogramPoint({required this.hz, this.left, this.right});
  final double hz;
  final double? left;
  final double? right;
}

/// Where a suggestion came from (shown next to it).
enum HealthSource { profile, walkingSteadiness, audiogram }

/// A need suggested from Health data. Only a suggestion: the user adds it
/// (or not), and nothing is saved without the consent checkbox.
class HealthSuggestion {
  const HealthSuggestion(this.need, this.source, [this.value]);
  final CareNeed need;
  final HealthSource source;

  /// The reading behind it: steadiness in %, audiogram average in dB HL.
  final double? value;
}

/// Apple's "Low" / "Very low" walking steadiness starts below 40 %.
const lowWalkingSteadiness = 0.40;

/// WHO (1997) "moderate" hearing impairment or worse: a better-ear average
/// over 500 / 1000 / 2000 / 4000 Hz of 41 dB HL or more.
const hearingImpairedDbHl = 41.0;
const _ptaFrequencies = [500.0, 1000.0, 2000.0, 4000.0];

/// Pure-tone average for one ear over [_ptaFrequencies]; null if any of the
/// four is missing for that ear. Frequencies match within 5 %.
double? pureToneAverage(List<AudiogramPoint> points, {required bool left}) {
  var sum = 0.0;
  for (final f in _ptaFrequencies) {
    double? value;
    for (final p in points) {
      if ((p.hz - f).abs() <= f * 0.05) value = left ? p.left : p.right;
      if (value != null) break;
    }
    if (value == null) return null;
    sum += value;
  }
  return sum / _ptaFrequencies.length;
}

/// The better (lower) ear's average; null unless both ears are complete, as
/// the better ear can't be known from one ear alone.
double? betterEarAverage(List<AudiogramPoint> points) {
  final l = pureToneAverage(points, left: true);
  final r = pureToneAverage(points, left: false);
  if (l == null || r == null) return null;
  return math.min(l, r);
}

/// Needs suggested by [reading] (empty when nothing points to a need).
List<HealthSuggestion> healthSuggestions(HealthReading reading) {
  final out = <HealthSuggestion>[];
  if (reading.wheelchairUse == 'yes') {
    out.add(const HealthSuggestion(CareNeed.wheelchair, HealthSource.profile));
  }
  final steadiness = reading.walkingSteadiness;
  if (steadiness != null && steadiness < lowWalkingSteadiness) {
    out.add(HealthSuggestion(CareNeed.reducedMobility, HealthSource.walkingSteadiness, steadiness * 100));
  }
  final hearing = betterEarAverage(reading.audiogram);
  if (hearing != null && hearing >= hearingImpairedDbHl) {
    out.add(HealthSuggestion(CareNeed.hearingImpaired, HealthSource.audiogram, hearing));
  }
  return out;
}
