"""Signature rules: one window per label, the fallbacks, and the hold properties."""

from __future__ import annotations

import pytest

from app.analytics.signature.features import extract_features, parse_snapshot
from app.analytics.signature.rules import LABELS, SignatureAssessment, assess
from tests.hardware_docs import air_doc
from tests.signature_windows import scenario_snapshots


def _assess(name: str) -> SignatureAssessment:
    return assess(extract_features(scenario_snapshots(name)))


@pytest.mark.parametrize(("scenario", "label", "confidence"), [
    ("steam", "steam", 1.0),
    ("cooking", "cooking", 1.0),
    ("aerosol", "aerosol", 1.0),
    ("gas_leak", "gas_leak", 1.0),
    ("smouldering_fire", "smouldering_fire", 1.0),
    ("flaming_fire", "flaming_fire", 1.0),
    ("normal", "normal", 0.8),
    ("humidity_only", "unknown", 0.0),
])
def test_scenarios_get_their_label(scenario, label, confidence):
    a = _assess(scenario)
    assert (a.label, a.confidence) == (label, pytest.approx(confidence))
    assert set(a.scores) == set(LABELS)


def test_steam_humidity_rules_out_cooking():
    a = _assess("steam")  # rh_delta 28.5 is outside cooking's core 3..12
    assert a.scores["cooking"] == 0.0
    assert a.scores["steam"] == pytest.approx(1.0)


def test_occupied_early_smoulder_is_not_holdable_as_cooking():
    a = _assess("occupied_early_smoulder")  # CO only 3 -> 9 ppm, humidity flat, someone home
    assert not a.allows_hold
    assert a.label != "cooking"


def test_short_window_is_unknown():
    a = assess(extract_features(scenario_snapshots("steam")[:3]))
    assert (a.label, a.confidence, a.evidence) == ("unknown", 0.0, ["insufficient data"])


def test_window_without_hazard_channels_is_unknown():
    doc = air_doc(co={"valid": False}, gas={"state": "fault"}, particulate={"valid": False})
    a = assess(extract_features([parse_snapshot(i * 15.0, doc) for i in range(10)]))
    assert a.label == "unknown" and a.evidence == ["insufficient data"]


def test_evidence_lists_met_conditions_and_a_summary():
    a = _assess("steam")
    assert "rh_delta >= 12" in a.evidence
    assert "coarse_share >= 1.5" in a.evidence
    assert a.evidence[-1] == (
        "PM2.5 +151% of warn, CO flat, gas flat, humidity +28 pts, temperature +1.6 °C, occupied → steam"
    )


@pytest.mark.parametrize(("scenario", "overrides", "allows"), [
    ("steam", False, True),
    ("cooking", False, True),
    ("aerosol", False, True),
    ("smouldering_fire", True, False),
    ("flaming_fire", True, False),
    ("gas_leak", False, False),
    ("normal", False, False),
    ("humidity_only", False, False),
])
def test_hold_properties(scenario, overrides, allows):
    a = _assess(scenario)
    assert (a.overrides_hold, a.allows_hold) == (overrides, allows)


def test_a_middling_fire_score_blocks_a_benign_hold_without_overriding():
    scores = dict.fromkeys(LABELS, 0.0) | {"steam": 0.9, "smouldering_fire": 0.5}
    a = SignatureAssessment("steam", 0.9, scores, [])
    assert a.fire_score == 0.5
    assert not a.allows_hold and not a.overrides_hold


def test_low_confidence_benign_label_does_not_hold():
    scores = dict.fromkeys(LABELS, 0.0) | {"cooking": 0.625}
    assert not SignatureAssessment("cooking", 0.625, scores, []).allows_hold
