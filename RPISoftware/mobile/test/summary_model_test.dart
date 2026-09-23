import 'dart:convert';

import 'package:canary_resident/src/models/summary.dart';
import 'package:flutter_test/flutter_test.dart';

// Shaped like docs/HARDWARE.md §4 `BuildingSummary`.
const _contractJson = '''
{
  "building_id": "bld_007", "generated_ts": "2026-09-23T12:00:00Z",
  "status": "attention", "headline": "Leak cleared — inspect",
  "nodes_total": 2, "nodes_online": 1, "active_incidents": 0,
  "zones": [
    {"zone_id": "zone_kitchen", "zone_label": "Bucatarie", "status": "attention", "occupied": true,
     "nodes": [
       {"node_id": "canary", "kind": "air", "name": "canary", "zone_id": "zone_kitchen",
        "online": true, "stale": false, "last_seen_ts": "2026-09-23T12:00:00Z",
        "status": "ok", "headline": "Air is good", "advice": [],
        "indicators": [
          {"key": "air_quality", "label": "Air quality", "level": "ok", "value": "Good", "detail": "AQI 29", "trend": "stable"},
          {"key": "co", "label": "Carbon monoxide", "level": "ok", "value": "Safe", "detail": null, "trend": null}
        ]},
       {"node_id": "water-sensor", "kind": "water", "name": "Sink", "zone_id": "zone_kitchen",
        "online": false, "stale": true, "last_seen_ts": "2026-09-23T11:50:00Z",
        "status": "attention", "headline": "Leak cleared — inspect",
        "advice": ["Check under the sink for water.", "Reset the sensor once dry."],
        "indicators": [
          {"key": "leak", "label": "Leak", "level": "attention", "value": "Leak cleared — inspect", "detail": null, "trend": null},
          {"key": "valve", "label": "Valve", "level": "ok", "value": "Open", "detail": null, "trend": null},
          {"key": "health", "label": "Health", "level": "attention", "value": "Offline", "detail": null, "trend": null}
        ]}
     ]},
    {"zone_id": "zone_bath", "zone_label": "Baie", "status": "ok", "occupied": null, "nodes": []}
  ]
}
''';

void main() {
  test('parses a contract-shaped BuildingSummary', () {
    final s = BuildingSummary.fromJson(jsonDecode(_contractJson) as Map<String, dynamic>);

    expect(s.buildingId, 'bld_007');
    expect(s.generatedTs, DateTime.utc(2026, 9, 23, 12));
    expect(s.status, 'attention');
    expect(s.headline, 'Leak cleared — inspect');
    expect([s.nodesTotal, s.nodesOnline, s.activeIncidents], [2, 1, 0]);
    expect(s.hasNodes, isTrue);
    expect(s.zones.map((z) => z.zoneLabel), ['Bucatarie', 'Baie']);
    expect(s.zones[0].occupied, isTrue);
    expect(s.zones[1].occupied, isNull);

    final air = s.node('canary')!;
    expect([air.kind, air.status, air.headline], ['air', 'ok', 'Air is good']);
    expect(air.isLive, isTrue);
    expect(air.indicators.map((i) => i.key), ['air_quality', 'co']);
    final aq = air.indicators.first;
    expect([aq.label, aq.level, aq.value, aq.detail, aq.trend], ['Air quality', 'ok', 'Good', 'AQI 29', 'stable']);
    expect(air.indicators[1].detail, isNull);
    expect(air.indicators[1].trend, isNull);

    final water = s.node('water-sensor')!;
    expect(water.name, 'Sink');
    expect(water.isLive, isFalse);
    expect(water.lastSeenTs, DateTime.utc(2026, 9, 23, 11, 50));
    expect(water.advice, hasLength(2));
    expect(water.indicators.map((i) => i.key), ['leak', 'valve', 'health']);
  });

  test('tolerates missing and mistyped fields', () {
    final empty = BuildingSummary.fromJson(const {});
    expect(empty.zones, isEmpty);
    expect(empty.hasNodes, isFalse);
    expect(empty.status, 'unknown');

    final s = BuildingSummary.fromJson(const {
      'nodes_total': 'two',
      'zones': [
        'junk',
        {
          'occupied': 'yes',
          'nodes': [
            {'node_id': 'n1', 'online': true, 'advice': 'none', 'indicators': [42, {'key': 'co'}]},
            {'node_id': 'n2', 'online': 'true'},
          ],
        },
      ],
    });
    expect(s.zones, hasLength(1));
    expect(s.zones.single.occupied, isNull);
    expect([s.nodesTotal, s.nodesOnline], [2, 1]); // derived from the listed nodes
    final n1 = s.node('n1')!;
    expect(n1.name, 'n1');
    expect(n1.advice, isEmpty);
    expect(n1.indicators.single.level, 'unknown');
    expect(n1.indicators.single.value, '—');
    expect(s.node('n2')!.online, isFalse);
  });
}
