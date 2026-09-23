"""Pure environment analysis: AQI, indicator levels, freshness, trends, building summary."""

from __future__ import annotations

import json
from dataclasses import asdict
from datetime import datetime, timedelta, timezone

import pytest

from app.analytics.environment import (
    OpenIncident,
    analyze_node,
    aqi_category,
    pm10_aqi,
    pm25_aqi,
    summarize_building,
    trend,
)
from tests.hardware_docs import air_doc, water_doc

NOW = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


def _analyze(kind: str, doc: dict, *, online: bool = True, age_s: float = 5, history=None, node_id=None):
    return analyze_node(
        node_id=node_id or kind, kind=kind, name=node_id or kind, zone_id="zone_hallway", online=online,
        last_seen_ts=NOW - timedelta(seconds=age_s), status=doc, now=NOW, history=history,
    )


def _ind(analysis) -> dict:
    return {i.key: i for i in analysis.indicators}


def test_aqi_breakpoints():
    assert [pm25_aqi(c) for c in (0, 9.0, 9.05, 9.1, 35.4, 35.5, 55.4, 55.5, 125.4, 125.5)] == [
        0, 50, 50, 51, 100, 101, 150, 151, 200, 201,
    ]
    assert [pm25_aqi(c) for c in (225.4, 225.5, 325.4, 900)] == [300, 301, 500, 500]
    assert pm25_aqi(12) == 56
    assert [pm10_aqi(c) for c in (0, 54, 54.9, 55, 154, 155, 424, 425, 604, 900)] == [
        0, 50, 50, 51, 100, 101, 300, 301, 500, 500,
    ]
    assert [aqi_category(a) for a in (50, 51, 101, 151, 201, 301)] == [
        ("Good", "ok"),
        ("Moderate", "ok"),
        ("Unhealthy for sensitive groups", "attention"),
        ("Unhealthy", "attention"),
        ("Very unhealthy", "danger"),
        ("Hazardous", "danger"),
    ]


def test_air_sample_is_all_good():
    a = _analyze("air", air_doc())
    assert [i.key for i in a.indicators] == ["air_quality", "co", "gas", "comfort", "occupancy", "health"]
    ind = _ind(a)
    assert (ind["air_quality"].value, ind["air_quality"].level, ind["air_quality"].detail) == ("Good", "ok", "AQI 39")
    assert (ind["co"].value, ind["gas"].value, ind["comfort"].value) == ("Safe", "Safe", "Comfortable")
    assert (ind["occupancy"].value, ind["health"].value) == ("Occupied", "Online")
    assert (a.status, a.headline, a.advice, a.stale) == ("ok", "Air is good", [], False)


def test_air_quality_takes_the_worse_pollutant_and_device_danger():
    ind = _ind(_analyze("air", air_doc(particulate={"pm2_5": 7, "pm10": 200})))["air_quality"]
    assert (ind.value, ind.level, ind.detail) == ("Unhealthy for sensitive groups", "attention", "AQI 123")
    # the installer's own danger grading forces danger even on a moderate AQI
    ind = _ind(_analyze("air", air_doc(particulate={"pm2_5": 20, "state": "danger"})))["air_quality"]
    assert (ind.value, ind.level, ind.detail) == ("Particulate alarm", "danger", "AQI 71")
    ind = _ind(_analyze("air", air_doc(particulate={"pm2_5": 5, "state": "warning"})))["air_quality"]
    assert (ind.value, ind.level) == ("Particulate warning", "attention")
    ind = _ind(_analyze("air", air_doc(particulate={"state": "fault", "valid": False})))["air_quality"]
    assert (ind.value, ind.level) == ("Sensor fault", "attention")


@pytest.mark.parametrize(
    "state,value,level",
    [
        ("ok", "Safe", "ok"),
        ("warning", "Elevated", "attention"),
        ("danger", "Dangerous", "danger"),
        ("warmup", "Warming up", "unknown"),
        ("fault", "Sensor fault", "attention"),
    ],
)
def test_co_and_gas_levels_follow_device_grading(state, value, level):
    ind = _ind(_analyze("air", air_doc(co={"state": state}, gas={"state": state})))
    assert (ind["co"].value, ind["co"].level) == (value, level)
    assert (ind["gas"].value, ind["gas"].level) == (value, level)


def test_invalid_co_is_no_data_and_co_danger_advises_leaving():
    ind = _ind(_analyze("air", air_doc(co={"valid": False})))
    assert (ind["co"].value, ind["co"].level) == ("No data", "unknown")

    a = _analyze("air", air_doc(co={"ppm": 180, "state": "danger"}))
    assert (a.status, a.headline) == ("danger", "Dangerous carbon monoxide level")
    assert a.advice == ["Leave the area now and call 112"]


def test_leak_wet_vs_latched_vs_dry():
    closed = {"requested": "closed", "applied": "closed", "relay_active": True}
    wet = _analyze("water", water_doc(sensor={"state": "wet"}, leak_latched=True, valve=closed))
    ind = _ind(wet)
    assert [i.key for i in wet.indicators] == ["leak", "valve", "health"]
    assert (ind["leak"].value, ind["leak"].level) == ("Leak detected", "danger")
    assert (ind["valve"].value, ind["valve"].level) == ("Closed", "attention")
    assert (wet.status, wet.headline) == ("danger", "Water leak detected")
    assert wet.advice == [
        "Water supply was shut off automatically. Fix the leak and dry the sensor, then reopen the valve on the device."
    ]

    latched = _analyze("water", water_doc(leak_latched=True, valve=closed))
    assert (_ind(latched)["leak"].value, _ind(latched)["leak"].level) == ("Leak cleared — inspect", "attention")
    assert latched.status == "attention"

    dry = _analyze("water", water_doc())
    assert (_ind(dry)["leak"].value, _ind(dry)["valve"].value, dry.status, dry.headline) == (
        "No leak", "Open", "ok", "No leak",
    )
    not_ready = _analyze("water", water_doc(sensor={"initialized": False, "state": "uninitialized"}))
    assert (_ind(not_ready)["leak"].value, _ind(not_ready)["leak"].level) == ("Sensor not ready", "unknown")


def test_stale_and_offline_hide_hazards_and_need_attention():
    danger = air_doc(co={"ppm": 180, "state": "danger"})
    assert not _analyze("air", danger, age_s=44).stale
    stale = _analyze("air", danger, age_s=46)
    ind = _ind(stale)
    assert stale.stale and (ind["health"].value, ind["health"].level) == ("Stale", "attention")
    assert all(ind[k].value == "No data" for k in ("air_quality", "co", "gas", "comfort"))
    assert ind["occupancy"].value == "Unknown"
    assert (stale.status, stale.headline) == ("attention", "No recent data from the sensor")

    assert not _analyze("water", water_doc(), age_s=179).stale
    assert _analyze("water", water_doc(), age_s=181).stale

    offline = _analyze("water", water_doc(sensor={"state": "wet"}), online=False)
    ind = _ind(offline)
    assert (ind["health"].value, ind["leak"].value) == ("Offline", "No data")
    assert (offline.status, offline.headline) == ("attention", "Sensor offline")


def test_health_warmup_and_weak_wifi():
    warming = _analyze("air", air_doc(warmup_remaining_seconds=170, co={"state": "warmup"},
                                      gas={"state": "warmup"}, particulate={"state": "warmup"}))
    health = _ind(warming)["health"]
    assert (health.value, health.level, health.detail) == ("Warming up", "ok", "3 min left")
    assert (warming.status, warming.headline) == ("ok", "Sensor warming up")
    assert _ind(warming)["air_quality"].value == "Good"  # PM data is valid during the MQ5 warm-up

    weak = _analyze("air", air_doc(wifi={"rssi": -85}))
    assert (_ind(weak)["health"].value, weak.status) == ("Weak Wi-Fi", "attention")


def test_comfort_bands():
    def comfort(t, rh):
        c = _ind(_analyze("air", air_doc(climate={"temperature_c": t, "humidity_percent": rh})))["comfort"]
        return c.value, c.level

    assert comfort(22, 45) == ("Comfortable", "ok")
    assert comfort(27, 65) == ("Too warm, Too humid", "ok")
    assert comfort(15, 45) == ("Too cold", "attention")
    assert comfort(22, 75) == ("Too humid", "attention")
    assert comfort(22, 25) == ("Too dry", "ok")


def test_trends():
    t0 = NOW.timestamp() - 1500
    rising = [(t0 + i * 60, 3 + i * 0.5) for i in range(20)]
    assert trend(rising, warn=50) == "rising"
    assert trend([(t, 30 - (v - 3)) for t, v in rising], warn=50) == "falling"
    assert trend([(t0 + i * 60, 3) for i in range(20)], warn=50) == "stable"
    assert trend(rising[:2], warn=50) is None  # not enough points
    assert trend(rising, warn=None) is None

    a = _analyze("air", air_doc(), history={"co.ppm": rising, "particulate.pm2_5": [(t0 + i * 60, 7) for i in range(20)]})
    ind = _ind(a)
    assert (ind["co"].trend, ind["air_quality"].trend, ind["gas"].trend, ind["comfort"].trend) == (
        "rising", "stable", None, None,
    )


def _strip_ts(obj):
    if isinstance(obj, dict):
        return {k: _strip_ts(v) for k, v in obj.items() if not k.endswith("_ts")}
    if isinstance(obj, list):
        return [_strip_ts(v) for v in obj]
    return obj


def test_summary_never_contains_raw_measurements():
    air = _analyze("air", air_doc(
        co={"ppm": 41.3, "peak_ppm": 45.6}, gas={"adc": 1357, "peak_adc": 1468},
        particulate={"pm1_0": 11.1, "pm2_5": 12.9, "pm10": 31.7},
        climate={"temperature_c": 21.6, "humidity_percent": 44.4},
        presence={"stationary_distance_cm": 187, "detection_distance_cm": 187, "stationary_energy": 77},
        wifi={"rssi": -67}, warmup_remaining_seconds=0,
    ))
    water = _analyze("water", water_doc(sensor={"adc": 312}, wifi={"rssi": -58}))
    summary = summarize_building(building_id="bld_007", generated_ts=NOW, nodes=[air, water],
                                 zone_labels={"zone_hallway": "Hol"}, incidents=[])
    text = json.dumps(_strip_ts(asdict(summary)))
    for raw in ("41.3", "45.6", "1357", "1468", "11.1", "12.9", "31.7", "21.6", "44.4", "187", "77", "-67", "-58",
                "312", "600000", "123456"):
        assert raw not in text, raw
    for key in ("ppm", "adc", "pm1", "pm2", "pm10", "rssi", "temperature", "humidity", "distance", "uptime"):
        assert key not in text, key
    assert "AQI 58" in text  # the only number allowed besides warm-up minutes


def test_building_status_and_headline_rules():
    good = _analyze("air", air_doc(), node_id="canary")
    weak = _analyze("air", air_doc(wifi={"rssi": -90}), node_id="kitchen")
    leak = _analyze("water", water_doc(), node_id="water-sensor")

    def summary(nodes, incidents=()):
        return summarize_building(building_id="bld_007", generated_ts=NOW, nodes=nodes,
                                  zone_labels={"zone_hallway": "Hol"}, incidents=list(incidents))

    empty = summary([])
    assert (empty.status, empty.headline, empty.zones) == ("attention", "No sensors connected", [])
    ok = summary([good, leak])
    assert (ok.status, ok.headline, ok.nodes_total, ok.nodes_online) == ("ok", "All clear", 2, 2)
    assert [(z.zone_id, z.zone_label, z.status, z.occupied, len(z.nodes)) for z in ok.zones] == [
        ("zone_hallway", "Hol", "ok", True, 2)
    ]
    assert (summary([good, weak]).status, summary([good, weak]).headline) == ("attention", "Weak Wi-Fi signal")
    assert summary([leak]).zones[0].occupied is None  # no air node in the zone

    detection = OpenIncident("detection", "warning", "Gas leak — detection", NOW - timedelta(minutes=5))
    evacuation = OpenIncident("evacuation", "critical", "EVACUATE NOW — Carbon monoxide", NOW)
    s = summary([good], [detection])
    assert (s.status, s.headline, s.active_incidents) == ("attention", "Gas leak — detection", 1)
    s = summary([good], [detection, evacuation])
    assert (s.status, s.headline, s.active_incidents) == ("danger", "EVACUATE NOW — Carbon monoxide", 2)
    s = summary([], [evacuation])  # an alarm is never hidden behind "No sensors connected"
    assert (s.status, s.headline) == ("danger", "EVACUATE NOW — Carbon monoxide")
