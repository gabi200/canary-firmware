"""Pure sensor trust and drift checks."""

from __future__ import annotations

from app.analytics.anomalies import AnomalySample, assess_channel, is_stale


def sample(ts: float, value: float, **flags) -> AnomalySample:
    return AnomalySample(ts=ts, value=value, **flags)


def test_stale_after_three_intervals():
    assert is_stale(last_seen_ts=60, now_ts=91, interval_s=10)
    assert not is_stale(last_seen_ts=60, now_ts=90, interval_s=10)


def test_stuck_channel_ignores_duplicate_and_out_of_order_input():
    rows = [
        sample(150, 10),
        sample(110, 10),
        sample(130, 10),
        sample(110, 10),  # exact duplicate
        sample(0, 9),
        sample(40, 11),
    ]
    result = assess_channel(
        rows,
        now_ts=150,
        interval_s=10,
        reference_cutoff_ts=100,
        stuck_limit_s=30,
    )
    assert (result.state, result.reason, result.sample_count) == ("suspect", "stuck_channel", 5)


def test_binary_water_probe_staying_flat_is_ok():
    rows = [sample(0, 0), sample(20, 0), sample(110, 0), sample(150, 0)]
    result = assess_channel(
        rows,
        now_ts=150,
        interval_s=20,
        reference_cutoff_ts=100,
        stuck_limit_s=20,
        binary=True,
    )
    assert (result.state, result.reason) == ("ok", "ok")


def test_noise_rising_against_frozen_reference():
    reference = [sample(i * 10, 100 + (i % 2)) for i in range(8)]
    recent = [sample(110 + i * 10, 100 + (-1) ** i * 12) for i in range(6)]
    result = assess_channel(
        [*reference, *recent],
        now_ts=160,
        interval_s=10,
        reference_cutoff_ts=100,
    )
    assert (result.state, result.reason) == ("suspect", "noise_rising")


def test_baseline_shift_excludes_warmup_invalid_and_incident_samples():
    reference = [sample(i * 10, 100 + (i % 2)) for i in range(8)]
    excluded = [
        sample(20, 1000, warmup=True),
        sample(30, 1000, valid=False),
        sample(40, 1000, incident=True),
    ]
    recent = [sample(110 + i * 10, 130 + (i % 2)) for i in range(6)]
    result = assess_channel(
        [*recent, *excluded, *reference],
        now_ts=160,
        interval_s=10,
        reference_cutoff_ts=100,
    )
    assert (result.state, result.reason) == ("suspect", "baseline_shift_cause_unknown")

