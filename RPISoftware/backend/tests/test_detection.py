"""Pure detection-engine tests."""

from __future__ import annotations

from app.detection.engine import (
    CRITICAL,
    DETECTION,
    NORMAL,
    DetectionContext,
    evaluate,
    is_clearing,
    reading_level,
)
from app.enums import EdgeState, IncidentState, SensorType, Severity


def _ctx(state=IncidentState.normal, samples=1, devices=1, neighbor=False, unaccounted=False):
    return DetectionContext(
        current_state=state,
        samples_over_threshold=samples,
        distinct_devices_over=devices,
        neighbor_corroboration=neighbor,
        unaccounted_gt0=unaccounted,
    )


def test_reading_level_gas():
    assert reading_level(SensorType.combustible_gas, 100, EdgeState.normal) == NORMAL
    assert reading_level(SensorType.combustible_gas, 1500, EdgeState.normal) == DETECTION
    assert reading_level(SensorType.combustible_gas, 6000, EdgeState.normal) == CRITICAL
    # edge alarm forces critical regardless of value
    assert reading_level(SensorType.combustible_gas, 10, EdgeState.alarm) == CRITICAL


def test_wifi_presence_is_not_a_hazard():
    d = evaluate(SensorType.wifi_presence, 5, EdgeState.normal, _ctx())
    assert d.target_state is None


def test_first_detection_then_verification():
    d1 = evaluate(SensorType.combustible_gas, 1500, EdgeState.normal, _ctx(samples=1, devices=1))
    assert d1.target_state == IncidentState.detection
    assert not d1.fast_path
    d2 = evaluate(SensorType.combustible_gas, 1600, EdgeState.normal,
                  _ctx(state=IncidentState.detection, samples=2, devices=1))
    assert d2.target_state == IncidentState.verification


def test_corroboration_two_devices_reaches_alarm():
    d = evaluate(SensorType.combustible_gas, 1600, EdgeState.normal,
                 _ctx(state=IncidentState.verification, samples=2, devices=2))
    assert d.target_state == IncidentState.alarm
    assert d.fast_path


def test_critical_gas_auto_evacuates_and_escalates():
    d = evaluate(SensorType.combustible_gas, 6000, EdgeState.normal, _ctx())
    assert d.target_state == IncidentState.evacuation
    assert d.severity == Severity.critical
    assert d.escalation_warranted


def test_critical_water_leak_alarms_but_does_not_auto_evacuate():
    d = evaluate(SensorType.water_leak, 1, EdgeState.normal, _ctx())
    assert d.target_state == IncidentState.alarm  # not evacuation


def test_is_clearing():
    assert is_clearing(SensorType.combustible_gas, 100, EdgeState.normal)
    assert not is_clearing(SensorType.combustible_gas, 100, EdgeState.warn)
    assert not is_clearing(SensorType.combustible_gas, 2000, EdgeState.normal)


def test_insane_device_thresholds_fall_back_to_backend_defaults():
    from app.detection.engine import is_clearing
    from app.detection.thresholds import Thresholds, effective_thresholds, thresholds_for

    default = thresholds_for(SensorType.co)
    for bad in (
        Thresholds(detection=0, critical=0, clear=0, units="ppm"),  # 0/0: normal reading would be critical
        Thresholds(detection=-5, critical=-1, clear=-5, units="ppm"),
        Thresholds(detection=100, critical=50, clear=100, units="ppm"),  # inverted
        Thresholds(detection=float("nan"), critical=100, clear=50, units="ppm"),
    ):
        assert effective_thresholds(SensorType.co, bad) is default
        assert reading_level(SensorType.co, 3, EdgeState.normal, bad) == "normal"
        assert is_clearing(SensorType.co, 0, EdgeState.normal, bad)
    good = Thresholds(detection=50, critical=100, clear=50, units="ppm")
    assert effective_thresholds(SensorType.co, good) is good
    # a device's own alarm is never downgraded, whatever it says its thresholds are
    assert reading_level(SensorType.co, 3, EdgeState.alarm, Thresholds(1e9, 2e9, 1e9, "ppm")) == "critical"
