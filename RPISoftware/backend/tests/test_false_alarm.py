"""Pure false-alarm classifier tests."""

from __future__ import annotations

from app.analytics.false_alarm import (
    DRIFT,
    GENUINE,
    INSUFFICIENT_DATA,
    LIKELY_BENIGN,
    MICRO_LEAK_TREND,
    TRANSIENT,
    ReadingSample,
    classify,
)

DET, CRIT, CLR = 1000.0, 5000.0, 500.0


def C(samples, *, multi_sensor=False, edge_alarm=False):
    return classify(samples, detection=DET, critical=CRIT, clear=CLR,
                    multi_sensor=multi_sensor, edge_alarm=edge_alarm)


def S(ts, v):
    return ReadingSample(ts=float(ts), value=float(v))


def test_critical_is_always_genuine_even_single_sample():
    a = C([S(0, 6000)])
    assert a.classification == GENUINE and not a.suppress_escalation


def test_edge_alarm_is_genuine():
    a = C([S(0, 200), S(10, 210)], edge_alarm=True)
    assert a.classification == GENUINE and not a.suppress_escalation


def test_single_sample_is_insufficient():
    a = C([S(0, 1200)])
    assert a.classification == INSUFFICIENT_DATA and not a.suppress_escalation


def test_transient_spike_is_suppressed():
    a = C([S(0, 1200), S(20, 1400), S(40, 300)])  # rose then fell below clear, brief
    assert a.classification == TRANSIENT and a.suppress_escalation


def test_oscillatory_cooking_is_suppressed():
    a = C([S(0, 1200), S(20, 300), S(40, 1300), S(60, 200), S(80, 1250)])
    assert a.classification == TRANSIENT and a.suppress_escalation


def test_single_flat_marginal_is_held():
    a = C([S(0, 1050), S(10, 1050), S(20, 1050)])  # flat, just over, one sensor
    assert a.classification == LIKELY_BENIGN and a.suppress_escalation


def test_multi_sensor_sustained_is_genuine():
    a = C([S(0, 1050), S(10, 1060), S(20, 1070)], multi_sensor=True)
    assert a.classification == GENUINE and not a.suppress_escalation


def test_rising_single_sensor_is_genuine():
    # clearly rising (> ~0.5 ppm/s) even from one sensor -> real leak, not held
    a = C([S(0, 1000), S(100, 1100), S(200, 1300)])
    assert a.classification == GENUINE and not a.suppress_escalation


def test_micro_leak_trend_below_threshold():
    a = C([S(0, 300), S(120, 550), S(240, 780), S(360, 920)])  # sub-threshold, rising, long span
    assert a.classification == MICRO_LEAK_TREND


def test_drift_slow_flat_creep():
    a = C([S(0, 1050), S(1800, 1080)])  # long span, nearly flat, near threshold
    assert a.classification == DRIFT and a.suppress_escalation
