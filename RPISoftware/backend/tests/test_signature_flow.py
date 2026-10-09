"""Hazard signature classifier end to end through hardware ingest."""

from __future__ import annotations

import dataclasses
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.analytics.service import AnalyticsService
from app.analytics.signature.model import ShadowPrediction
from app.analytics.signature.rules import assess
from app.db import SessionLocal
from app.ingestion import hardware
from app.models import SignatureAssessmentRow
from app.retention import prune_old_rows
from tests.conftest import auth_token, telemetry
from tests.hardware_docs import air_doc, water_doc
from tests.signature_windows import publish, seed_history


@pytest.fixture(autouse=True)
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


@pytest.fixture
def no_classifier(monkeypatch):
    async def broken(self, node_id: str, incident_id: str):
        raise RuntimeError("classifier down")
    monkeypatch.setattr(AnalyticsService, "classify_signature", broken)


async def _active(client) -> list[dict]:
    headers = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    r = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True}, headers=headers)
    return r.json()


async def _assessments(incident_id: str) -> list[SignatureAssessmentRow]:
    async with SessionLocal() as s:
        q = (select(SignatureAssessmentRow).where(SignatureAssessmentRow.incident_id == incident_id)
             .order_by(SignatureAssessmentRow.id))
        return list((await s.scalars(q)).all())


async def _publish_all(docs: list[dict]) -> None:
    for doc in docs:
        await publish("canary", doc)


async def test_corroborated_steam_is_held_in_verification(client):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert (inc["hazard_type"], inc["state"]) == ("particulate", "verification")
    assert inc["false_alarm_class"] == "genuine"  # the old layer alone would have alarmed
    rows = await _assessments(inc["id"])
    assert len(rows) == 3
    assert (rows[-1].node_id, rows[-1].label, rows[-1].confidence) == ("canary", "steam", pytest.approx(1.0))


async def test_steam_without_the_classifier_reaches_alarm(client, no_classifier):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert inc["state"] == "alarm"
    assert await _assessments(inc["id"]) == []


async def test_fire_signature_cancels_a_false_alarm_hold(client):
    await _publish_all(await seed_history("smouldering_fire", readings=False))
    [inc] = await _active(client)
    assert inc["false_alarm_class"] == "likely_benign"
    assert inc["state"] == "alarm"


async def test_flat_smoke_is_held_without_the_classifier(client, no_classifier):
    await _publish_all(await seed_history("smouldering_fire", readings=False))
    [inc] = await _active(client)
    assert (inc["false_alarm_class"], inc["state"]) == ("likely_benign", "verification")


async def test_critical_reading_during_steam_is_not_held(client):
    live = await seed_history("steam")
    await _publish_all(live)
    await publish("canary", air_doc(uptime_ms=live[-1]["uptime_ms"] + 15000,
                                    particulate={"pm2_5": 200, "pm10": 260, "state": "danger"}))
    [inc] = await _active(client)
    assert inc["state"] == "alarm"


async def test_gas_leak_during_cooking_reaches_alarm(client):
    await _publish_all(await seed_history("cooking_gas_leak", reading_channels=("particulate", "gas")))
    by_hazard = {inc["hazard_type"]: inc for inc in await _active(client)}
    gas = by_hazard["combustible_gas"]
    assert gas["false_alarm_class"] == "genuine"  # the false-alarm layer does not hold it
    assert gas["state"] == "alarm"
    assert (await _assessments(gas["id"]))[-1].label == "cooking"  # the benign label was there, and ignored


async def test_two_zone_corroboration_during_steam_reaches_alarm(client):
    live = await seed_history("steam")
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_pm_kitchen", "particulate", 60, zone_id="zone_kitchen", unit_id="unit_0312", units="ug/m3"))
    assert r.status_code < 300, r.text
    await _publish_all(live)
    [inc] = await _active(client)
    assert sorted(inc["affected_zone_ids"]) == ["zone_hallway", "zone_kitchen"]
    assert inc["state"] == "alarm"
    assert (await _assessments(inc["id"]))[-1].label == "steam"


async def test_edge_alarm_during_steam_is_not_held(client):
    live = await seed_history("steam")
    await _publish_all(live)
    [held] = await _active(client)
    assert held["state"] == "verification"  # pm2_5 60 is under danger: only the node's flag differs below
    await publish("canary", air_doc(uptime_ms=live[-1]["uptime_ms"] + 15000,
                                    particulate={"pm2_5": 60, "pm10": 140, "state": "danger"}))
    [inc] = await _active(client)
    assert inc["state"] == "alarm"


async def test_shadow_prediction_never_changes_the_outcome(client, monkeypatch):
    monkeypatch.setattr("app.analytics.signature.model.predict",
                        lambda features, path=None: ShadowPrediction("smouldering_fire", 0.99, "test"))
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert inc["state"] == "verification"
    row = (await _assessments(inc["id"]))[-1]
    assert (row.label, row.shadow_label, row.shadow_confidence, row.model_version) == (
        "steam", "smouldering_fire", 0.99, "test")


async def test_water_node_gets_no_signature(client):
    await publish("water-sensor", water_doc(uptime_ms=1000))
    await publish("water-sensor", water_doc(uptime_ms=2000, sensor={"state": "wet", "adc": 1500}, leak_latched=True))
    [inc] = await _active(client)
    assert (inc["hazard_type"], inc["state"]) == ("water_leak", "alarm")
    assert await _assessments(inc["id"]) == []


async def test_old_assessments_are_pruned(client):
    async with SessionLocal() as s:
        s.add(SignatureAssessmentRow(incident_id="inc_old", node_id="canary", label="steam", confidence=0.9,
                                     scores={}, evidence=[], ts=datetime.now(timezone.utc) - timedelta(days=30)))
        await s.commit()
    deleted = await prune_old_rows()
    assert deleted["signature_assessments"] == 1


async def test_assessment_insert_failure_is_isolated(client, monkeypatch):
    real_assess = assess

    def bad_assess(features):
        return dataclasses.replace(real_assess(features), label=None)  # NOT NULL violation at flush
    monkeypatch.setattr("app.analytics.service.assess", bad_assess)
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert inc["state"] == "alarm"
    assert await _assessments(inc["id"]) == []


async def test_incident_api_returns_the_latest_signature(client):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    sig = inc["signature"]
    assert set(sig) == {"label", "confidence", "evidence", "shadow_label", "shadow_confidence", "model_version", "ts"}
    assert (sig["label"], sig["confidence"]) == ("steam", pytest.approx(1.0))
    assert sig["evidence"][-1].endswith("→ steam")
    headers = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    one = (await client.get(f"/api/v1/incidents/{inc['id']}", headers=headers)).json()
    assert one["signature"] == sig


async def test_incident_without_assessment_has_null_signature(client):
    for seq in (1, 2):
        await client.post("/api/v1/telemetry", json=telemetry(
            "dev_gas_kitchen", "combustible_gas", 1200, zone_id="zone_kitchen", unit_id="unit_0312", seq=seq))
    [inc] = await _active(client)
    assert inc["signature"] is None


async def test_dismiss_returns_the_signature_too(client):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    headers = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    r = await client.post(f"/api/v1/incidents/{inc['id']}/dismiss", headers=headers)
    assert r.status_code == 200, r.text
    assert r.json()["signature"]["label"] == "steam"
