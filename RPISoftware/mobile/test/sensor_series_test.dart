import 'package:canary_resident/src/logic/sensor_series.dart';
import 'package:canary_resident/src/models/history.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 10, 9, 20);

NodeHistory _history(List<Map<String, Object?>> values, {Duration step = const Duration(seconds: 15)}) =>
    NodeHistory.fromJson({
      'node_id': 'air-kitchen',
      'minutes': 60,
      'fields': const ['x'],
      'points': [
        for (var i = 0; i < values.length; i++)
          {'ts': _t0.add(step * i).toIso8601String(), 'values': values[i]},
      ],
    }, now: _t0.add(const Duration(minutes: 30)));

void main() {
  group('Series', () {
    test('nulls are gaps: they split runs and never become 0', () {
      final s = Series.of(_history([
        {'x': 1}, {'x': 2}, {'x': null}, {'x': 4}, {'x': null}, {'x': null}, {'x': 7},
      ]), 'x');
      final runs = s.runs(maxGap: const Duration(minutes: 1));
      expect(runs.map((r) => r.map((p) => p.value).toList()), [
        [1, 2],
        [4],
        [7],
      ]);
      expect(runs.expand((r) => r).any((p) => p.value == 0), isFalse);
    });

    test('a silence longer than maxGap splits a run', () {
      final h = NodeHistory.fromJson({
        'node_id': 'n', 'minutes': 60,
        'points': [
          {'ts': _t0.toIso8601String(), 'values': {'x': 1}},
          {'ts': _t0.add(const Duration(seconds: 15)).toIso8601String(), 'values': {'x': 2}},
          {'ts': _t0.add(const Duration(minutes: 10)).toIso8601String(), 'values': {'x': 3}},
        ],
      }, now: _t0.add(const Duration(minutes: 20)));
      expect(Series.of(h, 'x').runs(maxGap: const Duration(minutes: 1)).length, 2);
      expect(Series.of(h, 'x').runs(maxGap: const Duration(minutes: 15)).length, 1);
    });

    test('min / max ignore nulls; latest and warming up', () {
      final s = Series.of(_history([{'x': null}, {'x': 21.1}, {'x': 23.0}, {'x': 22.4}]), 'x');
      expect(s.range, (min: 21.1, max: 23.0));
      expect(s.latest, 22.4);
      expect(s.warmingUp, isFalse);

      final warming = Series.of(_history([{'x': 5}, {'x': null}]), 'x');
      expect(warming.latest, isNull);
      expect(warming.warmingUp, isTrue);
      expect(warming.range, (min: 5.0, max: 5.0));

      final allNull = Series.of(_history([{'x': null}, {'x': null}]), 'x');
      expect(allNull.range, isNull);
      expect(allNull.runs(maxGap: const Duration(minutes: 1)), isEmpty);
      expect(Series.of(_history([]), 'x').warmingUp, isFalse);
    });

    test('mapped series (gas % of warning) keep their gaps', () {
      final s = Series.of(_history([{'g': 750}, {'g': null}, {'g': 1500}]), 'g', map: (v) => gasPercent(v, 1500));
      expect(s.points.map((p) => p.value), [50, null, 100]);
    });

    test('parsing tolerates bad values and orders points', () {
      final h = NodeHistory.fromJson({
        'node_id': 'n', 'minutes': 60,
        'points': [
          {'ts': _t0.add(const Duration(minutes: 1)).toIso8601String(), 'values': {'x': 'bad'}},
          {'ts': 'not a date', 'values': {'x': 1}},
          {'ts': _t0.toIso8601String(), 'values': {'x': 2}},
          'junk',
        ],
      }, now: _t0.add(const Duration(minutes: 5)));
      expect(h.points.map((p) => p['x']), [2, null]);
      expect(h.start, h.end.subtract(const Duration(minutes: 60)));
    });

    test('chart bounds include the warning line', () {
      final s = Series.of(_history([{'x': 3}, {'x': 5}]), 'x');
      final b = chartBounds(s, threshold: 50);
      expect(b.min, 0);
      expect(b.max, greaterThan(50));
      final temp = chartBounds(Series.of(_history([{'x': 22.0}, {'x': 22.2}]), 'x'), zeroBased: false, minSpan: 2);
      expect(temp.max - temp.min, greaterThanOrEqualTo(2));
      expect(temp.min, lessThan(22.0));
    });
  });

  group('plain-language words', () {
    test('gas level is a % of the warning threshold, clamped 0–999', () {
      expect(gasPercent(682, 1500), closeTo(45.5, 0.1));
      expect(gasPercent(0, 1500), 0);
      expect(gasPercent(99999, 1500), 999);
      expect(gasPercent(100, 0), 0);
    });

    test('gas word boundaries: <60 normal, ≤100 elevated, >100 danger', () {
      expect(gasVerdict(0), Verdict.normal);
      expect(gasVerdict(59.9), Verdict.normal);
      expect(gasVerdict(60), Verdict.elevated);
      expect(gasVerdict(100), Verdict.elevated);
      expect(gasVerdict(100.1), Verdict.danger);
      expect(gasVerdict(999), Verdict.danger);
    });

    test('CO, particles, temperature, humidity', () {
      expect(coVerdict(4), Verdict.safe);
      expect(coVerdict(50, warn: 50, danger: 100), Verdict.elevated);
      expect(coVerdict(100, warn: 50, danger: 100), Verdict.danger);
      expect(pm25Verdict(7), Verdict.good);
      expect(pm25Verdict(20, warn: 35, danger: 150), Verdict.moderate);
      expect(pm25Verdict(60, warn: 35, danger: 150), Verdict.poor);
      expect(pm25Verdict(151, warn: 35, danger: 150), Verdict.danger);
      expect(pm10Verdict(9), Verdict.good);
      expect(temperatureVerdict(22.4), Verdict.comfortable);
      expect(temperatureVerdict(17), Verdict.cool);
      expect(humidityVerdict(41), Verdict.humidityOk);
      expect(humidityVerdict(75), Verdict.humid);
      expect(Verdict.danger.tone, Tone.danger);
      expect(Verdict.safe.tone, Tone.ok);
    });

    test('leak state: latched flag or probe above its wet threshold', () {
      HistoryPoint p(Map<String, double?> v) => HistoryPoint(ts: _t0, values: v);
      expect(isWet(p({'leak_latched': 0, 'sensor.adc': 300, 'sensor.wet_threshold': 1200})), isFalse);
      expect(isWet(p({'leak_latched': 1})), isTrue);
      expect(isWet(p({'leak_latched': 0, 'sensor.adc': 1300, 'sensor.wet_threshold': 1200})), isTrue);
      expect(isWet(p({'leak_latched': null, 'sensor.adc': null})), isNull);
    });

    test('gap tolerance follows the reporting period and the window', () {
      expect(maxGapFor(minutes: 60, kind: 'air'), const Duration(minutes: 1));
      expect(maxGapFor(minutes: 60, kind: 'water'), const Duration(minutes: 4));
      expect(maxGapFor(minutes: 10080, kind: 'air'), const Duration(minutes: 84));
    });
  });
}
