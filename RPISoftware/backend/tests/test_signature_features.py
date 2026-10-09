"""Signature window features: parsing node_status documents and the feature maths."""

from __future__ import annotations

import pytest

from app.analytics.signature.features import (
    FEATURE_NAMES,
    SignatureFeatures,
    extract_features,
    parse_snapshot,
)
from tests.hardware_docs import air_doc


def snap(t: float, **sections):
    return parse_snapshot(t, air_doc(**sections))


def test_parse_snapshot_reads_usable_channels():
    s = parse_snapshot(12.0, air_doc())
    assert s.ts == 12.0
    assert s.values == {"co": 3, "gas": 640, "pm2_5": 7, "pm1_0": 4, "pm10": 9}
    assert s.warn == {"co": 50, "gas": 1500, "pm2_5": 35, "pm1_0": 35, "pm10": 100}
    assert (s.temperature_c, s.humidity_percent, s.presence) == (22.4, 41.5, True)


def test_parse_snapshot_drops_invalid_warmup_and_fault_channels():
    s = parse_snapshot(0.0, air_doc(
        co={"state": "warmup"}, gas={"state": "fault"}, particulate={"valid": False},
        climate={"valid": False}, presence={"valid": False},
    ))
    assert s.values == {} and s.warn == {}
    assert (s.temperature_c, s.humidity_percent, s.presence) == (None, None, None)


def test_parse_snapshot_tolerates_junk():
    empty = parse_snapshot(0.0, {})
    assert empty.values == {} and empty.presence is None
    assert parse_snapshot(0.0, "not a document").values == {}
    s = parse_snapshot(0.0, air_doc(
        co={"ppm": "3"}, gas={"warn_adc": 0}, climate={"temperature_c": True}, presence={"detected": "yes"},
    ))
    assert "co" not in s.values and "gas" not in s.values
    assert s.temperature_c is None and s.humidity_percent == 41.5
    assert s.presence is None


def test_feature_names_and_vector_order():
    assert FEATURE_NAMES[:3] == ("rise_co", "decay_co", "onset_s_co")
    assert FEATURE_NAMES[-2:] == ("n_samples", "span_s")
    assert len(FEATURE_NAMES) == 23
    f = extract_features([])
    assert len(f.as_vector()) == 23
    assert (f.n_samples, f.span_s) == (0.0, 0.0)
    assert f.rise_pm2_5 is None and f.presence_frac is None


def test_channel_rise_decay_and_onset():
    pm = [7, 7, 7, 7, 7, 7, 10, 30, 60, 50, 40, 30]
    f = extract_features([snap(i * 15.0, particulate={"pm2_5": v}) for i, v in enumerate(pm)])
    # baseline = median of the earliest third (4 samples) = 7; peak 60 at t=120
    assert f.rise_pm2_5 == pytest.approx(53 / 35)
    assert f.decay_pm2_5 == pytest.approx(30 / 53)
    # last sample <= 7 + 0.1 * 35 before the peak is t=90 (value 10)
    assert f.onset_s_pm2_5 == pytest.approx(30.0)
    assert f.rise_co == 0.0 and f.decay_co == 0.0
    assert (f.n_samples, f.span_s) == (12.0, 165.0)


def test_climate_deltas_and_temperature_rate():
    temps = [22, 22, 22, 22, 23, 25, 26, 26]
    f = extract_features([snap(i * 15.0, climate={"temperature_c": v, "humidity_percent": 40})
                          for i, v in enumerate(temps)])
    assert f.temp_delta == pytest.approx(4.0)
    assert f.temp_rate == pytest.approx(4.0)  # 22 -> 26 within 60 s
    assert f.rh_delta == pytest.approx(0.0)


def test_presence_fraction():
    flags = [True, False, True, True]
    f = extract_features([snap(i * 15.0, presence={"detected": v}) for i, v in enumerate(flags)])
    assert f.presence_frac == pytest.approx(0.75)


def test_pm_size_shares_use_raw_increases():
    rows = [(7, 4, 9)] * 4 + [(57, 34, 109)] * 2
    f = extract_features([snap(i * 15.0, particulate={"pm2_5": a, "pm1_0": b, "pm10": c})
                          for i, (a, b, c) in enumerate(rows)])
    assert f.fine_share == pytest.approx(30 / 50)
    assert f.coarse_share == pytest.approx(100 / 50)


def test_pm_size_shares_are_none_when_pm_is_flat():
    f = extract_features([snap(i * 15.0) for i in range(6)])
    assert f.fine_share is None and f.coarse_share is None


def test_missing_or_short_channels_are_none():
    f = extract_features([snap(i * 15.0, co={"valid": False}) for i in range(6)])
    assert f.rise_co is None and f.decay_co is None and f.onset_s_co is None
    short = extract_features([snap(0.0), snap(15.0)])
    assert short.rise_pm2_5 is None and short.temp_delta is None


def test_duplicate_timestamps_do_not_divide_by_zero():
    snaps = [snap(0.0), snap(0.0), snap(0.0, climate={"temperature_c": 30}), snap(0.0)]
    f = extract_features(snaps)
    assert f.span_s == 0.0
    assert f.temp_rate == 0.0


def test_snapshots_are_sorted_by_time():
    pm = [(30.0, 60), (0.0, 7), (15.0, 7), (45.0, 7)]
    f = extract_features([snap(t, particulate={"pm2_5": v}) for t, v in pm])
    assert f.decay_pm2_5 == pytest.approx(1.0)  # peak at t=30, back to 7 by t=45
    assert isinstance(f, SignatureFeatures)
