import 'dart:math' as math;

import 'package:canary_resident/src/logic/chart_math.dart';
import 'package:canary_resident/src/logic/floor_plan.dart';
import 'package:canary_resident/src/logic/sensor_series.dart';
import 'package:canary_resident/src/models/history.dart';
import 'package:flutter_test/flutter_test.dart';

final _t0 = DateTime.utc(2026, 10, 9, 20);

Series _series(List<double?> values, {Duration step = const Duration(minutes: 1)}) => Series.of(
      NodeHistory.fromJson({
        'node_id': 'n', 'minutes': 60,
        'points': [
          for (var i = 0; i < values.length; i++)
            {'ts': _t0.add(step * i).toIso8601String(), 'values': {'x': values[i]}},
        ],
      }, now: _t0.add(step * values.length)),
      'x',
    );

void main() {
  group('chart stats + crosshair', () {
    test('stats ignore nulls', () {
      final s = SeriesStats.of(_series([2, null, 4, 6, null]));
      expect([s.min, s.mean, s.max], [2, 4, 6]);
      expect(s.now, isNull, reason: 'newest reading is invalid');
      expect(SeriesStats.of(_series([null, null])).mean, isNull);
    });

    test('crosshair reads the nearest reading, and "no data" inside gaps', () {
      final s = _series([1, 2, null, 4]);
      const gap = Duration(minutes: 2);
      expect(readingAt(s, _t0.add(const Duration(seconds: 70)), maxGap: gap)!.value, 2);
      expect(readingAt(s, _t0.add(const Duration(minutes: 2)), maxGap: gap)!.value, isNull, reason: 'null reading');
      // Far from any reading (silence): no data rather than the nearest value.
      final sparse = Series.of(
        NodeHistory.fromJson({
          'node_id': 'n', 'minutes': 60,
          'points': [
            {'ts': _t0.toIso8601String(), 'values': {'x': 1}},
            {'ts': _t0.add(const Duration(minutes: 30)).toIso8601String(), 'values': {'x': 9}},
          ],
        }, now: _t0.add(const Duration(minutes: 40))),
        'x',
      );
      expect(readingAt(sparse, _t0.add(const Duration(minutes: 15)), maxGap: gap)!.value, isNull);
      expect(readingAt(sparse, _t0.add(const Duration(minutes: 30, seconds: 20)), maxGap: gap)!.value, 9);
      expect(readingAt(_series([]), _t0, maxGap: gap), isNull);
    });

    test('ticks', () {
      final ticks = timeTicks(_t0, _t0.add(const Duration(hours: 1)));
      expect(ticks.length, inInclusiveRange(2, 5));
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i].difference(ticks[i - 1]), ticks[1].difference(ticks[0]));
      }
      expect(valueTicks(0, 160), [0, 50, 100, 150]);
      expect(valueTicks(20.9, 23.4).first, greaterThanOrEqualTo(20.9));
    });
  });

  group('floor-plan grid', () {
    test('seeded flat: relative order kept', () {
      final g = gridLayout([
        (id: 'kitchen', x: 2, y: 2),
        (id: 'bedroom', x: 8, y: 2),
        (id: 'hallway', x: 5, y: 5),
        (id: 'boiler', x: 2, y: 8),
      ]);
      expect(g['kitchen'], (col: 0, row: 0));
      expect(g['bedroom'], (col: 2, row: 0));
      expect(g['hallway'], (col: 1, row: 1));
      expect(g['boiler'], (col: 0, row: 2));
    });

    test('never overlaps, for odd and identical positions', () {
      final rnd = math.Random(7);
      for (var trial = 0; trial < 200; trial++) {
        final n = 1 + rnd.nextInt(9);
        final rooms = [
          for (var i = 0; i < n; i++)
            // Coarse coordinates so duplicates and near-duplicates are common.
            (id: 'z$i', x: (rnd.nextInt(8) * 1.3).toDouble(), y: (rnd.nextInt(4) * 0.7).toDouble()),
        ];
        final g = gridLayout(rooms);
        expect(g.length, n);
        expect(g.values.toSet().length, n, reason: 'two rooms in one cell: $rooms');
        // Rows follow y: a clearly lower room is never placed above.
        for (final a in rooms) {
          for (final b in rooms) {
            if (b.y - a.y > 1.0) expect(g[a.id]!.row, lessThan(g[b.id]!.row));
          }
        }
      }
      expect(gridLayout([(id: 'a', x: 1, y: 1), (id: 'b', x: 1, y: 1)]).values.toSet().length, 2);
    });
  });
}
