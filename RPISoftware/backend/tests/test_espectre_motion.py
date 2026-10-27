"""ESPectre Wi-Fi motion boards: ingestion, dedup, zone states, staff-only API, and that motion
never reaches readings, incidents or occupancy."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select

from app.analytics import motion
from app.config import settings
from app.db import SessionLocal
from app.ingestion import espectre
from app.ingestion.mqtt import dispatch
from app.models import Incident, MotionObservation, MotionSensor, OccupancyEstimate, SensorReading
from tests.conftest import auth_token, telemetry

DEV = "3cf79180d3a0aca4"
BASE = f"espectre/v1/devices/{DEV}"
T0 = 1_800_000_000.0


@pytest.fixture(autouse=True)
def _boards(monkeypatch):
    monkeypatch.setattr(settings, "espectre_zones", {DEV: "zone_kitchen"})
    espectre.reset_state()
    yield
    espectre.reset_state()


async def _count(model, *where) -> int:
    async with SessionLocal() as s:
        return await s.scalar(select(func.count()).select_from(model).where(*where))


async def _ready(ts: float = T0) -> None:
    await dispatch(f"{BASE}/health", b'{"status":"ok","online":true,"uptime_s":40}', retain=True, received_ts=ts)
    await dispatch(f"{BASE}/sensing", b'{"ready":true,"calibrating":false,"threshold":0.4}', retain=True,
                   received_ts=ts)


async def _motion(ms: int, state: str, score: float, ts: float, **kw) -> None:
    body = json.dumps({"timestamp_ms": ms, "state": state, "score": score}).encode()
    await dispatch(f"{BASE}/motion", body, received_ts=ts, **kw)


async def _zone(client, user: str = "mihai") -> dict:
    token = await auth_token(client, user)
    resp = await client.get("/api/v1/buildings/bld_007/motion", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    return {z["zone_id"]: z for z in resp.json()["zones"]}


async def test_motion_is_stored_with_zone_and_receive_time(client):
    await _ready()
    await _motion(42_000, "motion", 0.71, T0 + 1)
    async with SessionLocal() as s:
        row = (await s.scalars(select(MotionObservation))).one()
    assert (row.device_id, row.zone_id, row.building_id, row.state, row.score, row.source_ms, row.ready) == \
        (DEV, "zone_kitchen", "bld_007", "motion", 0.71, 42_000, True)
    assert row.ts == datetime.fromtimestamp(T0 + 1, timezone.utc)


async def test_duplicate_and_out_of_order_motion_are_dropped(client):
    await _ready()
    await _motion(42_000, "motion", 0.7, T0)
    await _motion(42_000, "motion", 0.7, T0 + 0.5)  # QoS 1 redelivery
    await _motion(41_000, "idle", 0.1, T0 + 1)  # older evaluation arriving late
    assert await _count(MotionObservation) == 1
    async with SessionLocal() as s:
        assert (await s.get(MotionSensor, DEV)).last_motion_ts == datetime.fromtimestamp(T0, timezone.utc)


async def test_duplicate_after_hub_restart_is_dropped(client):
    await _ready()
    await _motion(42_000, "motion", 0.7, T0)
    espectre.reset_state()  # the in-memory state is gone, the database remembers
    await _motion(42_000, "motion", 0.7, T0 + 2)
    assert await _count(MotionObservation) == 1


async def test_reboot_restarts_the_clock_and_is_accepted(client):
    await _ready()
    await _motion(600_000, "motion", 0.7, T0)
    await _motion(3_000, "motion", 0.6, T0 + 20)  # rebooted: clock back near zero
    assert await _count(MotionObservation) == 2


async def test_unchanged_state_is_throttled_but_changes_are_kept(client):
    await _ready()
    for i in range(10):  # ten evaluations in one second
        await _motion(1_000 + i * 100, "idle", 0.05, T0 + i * 0.1)
    await _motion(2_100, "motion", 0.8, T0 + 1.1)  # a change is always stored
    await _motion(9_000, "motion", 0.8, T0 + 8)  # unchanged, after the store interval
    assert await _count(MotionObservation) == 3


async def test_retained_motion_and_malformed_messages_are_ignored(client):
    await _ready()
    await _motion(42_000, "motion", 0.7, T0, retain=True)
    for body in (b"not json", b"[]", b'{"timestamp_ms":"x","state":"motion","score":1}',
                 b'{"timestamp_ms":1,"state":"walking","score":1}', b'{"timestamp_ms":1,"state":"idle","score":NaN}'):
        await dispatch(f"{BASE}/motion", body, received_ts=T0)
    await dispatch("espectre/v1/devices/NOT-HEX/motion", b'{"timestamp_ms":1,"state":"motion","score":1}')
    assert await _count(MotionObservation) == 0


async def test_unmapped_board_is_listed_and_its_motion_not_stored(client, monkeypatch):
    monkeypatch.setattr(settings, "espectre_zones", {})
    await _ready()
    await _motion(42_000, "motion", 0.7, T0)
    assert await _count(MotionObservation) == 0
    token = await auth_token(client, "mihai")
    body = (await client.get("/api/v1/buildings/bld_007/motion", headers={"Authorization": f"Bearer {token}"})).json()
    assert [s["device_id"] for s in body["unmapped"]] == [DEV]
    assert {z["zone_id"]: z["state"] for z in body["zones"]}["zone_kitchen"] == "no_presence_sensor"


async def test_zone_states(client, monkeypatch):
    now = datetime.now(timezone.utc).timestamp()
    zones = await _zone(client)
    assert zones["zone_kitchen"]["state"] == "no_presence_sensor"  # no message from the board yet

    await dispatch(f"{BASE}/health", b'{"status":"ok","online":true}', retain=True, received_ts=now)
    assert (await _zone(client))["zone_kitchen"]["state"] == "unavailable"  # no sensing state yet

    await dispatch(f"{BASE}/sensing", b'{"ready":false,"calibrating":true}', retain=True, received_ts=now)
    assert (await _zone(client))["zone_kitchen"]["state"] == "calibrating"

    await dispatch(f"{BASE}/sensing", b'{"ready":true,"calibrating":false}', retain=True, received_ts=now)
    assert (await _zone(client))["zone_kitchen"]["state"] == "no_recent_motion"

    await _motion(50_000, "motion", 0.9, now)
    kitchen = (await _zone(client))["zone_kitchen"]
    assert kitchen["state"] == "motion" and kitchen["last_motion_age_s"] < 5
    assert (await _zone(client))["zone_bedroom"]["state"] == "no_presence_sensor"

    await dispatch(f"{BASE}/health", b'{"status":"offline","online":false}', retain=True, received_ts=now)
    assert (await _zone(client))["zone_kitchen"]["state"] == "unavailable"  # Last Will: never green


async def test_silent_board_turns_unavailable(client):
    old = (datetime.now(timezone.utc) - timedelta(seconds=motion.STALE_S + 5)).timestamp()
    await _ready(old)
    await _motion(5_000, "motion", 0.9, old)
    kitchen = (await _zone(client))["zone_kitchen"]
    assert kitchen["state"] == "unavailable"
    assert kitchen["last_motion_age_s"] > motion.STALE_S  # the age stays visible


async def test_motion_api_is_staff_only(client):
    for user in ("ana", "dispecer"):
        token = await auth_token(client, user)
        resp = await client.get("/api/v1/buildings/bld_007/motion", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 403, user
    assert (await client.get("/api/v1/buildings/bld_007/motion")).status_code == 401
    for user in ("tehnician", "admin"):
        await _zone(client, user)
    token = await auth_token(client, "mihai")
    resp = await client.get("/api/v1/buildings/nope/motion", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 404


async def test_motion_never_becomes_readings_occupancy_or_incidents(client):
    await _ready()
    await _motion(42_000, "motion", 0.7, T0)
    assert await _count(SensorReading) == 0
    assert await _count(OccupancyEstimate) == 0
    assert await _count(Incident) == 0


async def test_alarm_regression_gas_still_evacuates_with_idle_motion(client):
    """Alarm path untouched: an `idle` board in the same zone changes nothing about a critical leak."""
    now = datetime.now(timezone.utc).timestamp()
    await _ready(now)
    await _motion(42_000, "idle", 0.01, now)
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["incident_state"] == "evacuation"
