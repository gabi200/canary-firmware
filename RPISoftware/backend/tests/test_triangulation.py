"""Pure triangulation-engine tests."""

from __future__ import annotations

from app.analytics.triangulation import SensorPoint, triangulate

ZONES = {"a": (0.0, 0.0), "b": (10.0, 0.0), "c": (5.0, 5.0)}


def test_insufficient_data_when_all_below_baseline():
    sensors = [SensorPoint("d1", "a", 0, 0, value=100, baseline=1000)]
    r = triangulate(sensors, ZONES)
    assert r.source_zone_id is None
    assert r.confidence == 0.0
    assert r.n_contributors == 0


def test_single_sensor_locates_its_zone_with_modest_confidence():
    sensors = [SensorPoint("d1", "a", 0, 0, value=6000, baseline=1000)]
    r = triangulate(sensors, ZONES)
    assert r.source_zone_id == "a"
    assert r.n_contributors == 1
    # single sensor: zone known, not triangulated -> modest, capped confidence
    assert 0.3 <= r.confidence <= 0.4


def test_estimate_biases_toward_highest_concentration():
    sensors = [
        SensorPoint("d_hi", "a", 0, 0, value=6000, baseline=1000),
        SensorPoint("d_lo", "b", 10, 0, value=1500, baseline=1000),
    ]
    r = triangulate(sensors, ZONES)
    assert r.source_zone_id == "a"  # pulled toward the high-concentration sensor
    assert r.source_x is not None and r.source_x < 2.0
    assert r.n_contributors == 2
    assert "centroid" in r.method
    # top contributor is the high sensor
    assert r.contributors[0].device_id == "d_hi"
    assert r.contributors[0].weight > r.contributors[1].weight


def test_time_of_detection_breaks_ties():
    # equal concentration, but d_early detected first -> estimate leans to its zone
    sensors = [
        SensorPoint("d_early", "a", 0, 0, value=3000, baseline=1000, detected_ts=100.0),
        SensorPoint("d_late", "b", 10, 0, value=3000, baseline=1000, detected_ts=160.0),
    ]
    r = triangulate(sensors, ZONES)
    assert r.source_x is not None and r.source_x < 5.0  # closer to "a"
    assert "time" in r.method
