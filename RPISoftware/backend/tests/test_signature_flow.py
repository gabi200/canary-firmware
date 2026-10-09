"""Hazard signature classifier end to end through hardware ingest."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.analytics.service import AnalyticsService
from app.analytics.signature.model import ShadowPrediction
from app.db import SessionLocal
from app.ingestion import hardware
from app.models import SignatureAssessmentRow
from app.retention import prune_old_rows
from tests.conftest import auth_token
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
