"""F3b: structured fusion evidence items and the read-only evidence timeline."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select

from app.analytics import baseline as bl
from app.db import SessionLocal
from app.models import (
    Incident,
    IncidentEvent,
    MotionObservation,
    MotionSensor,
    SensorReading,
    TriangulationSnapshot,
    ZoneBaseline,
)
from tests.conftest import auth_token, telemetry


async def headers(client, username: str = "mihai") -> dict[str, str]:
    return {"Authorization": f"Bearer {await auth_token(client, username)}"}


def gas(seq: int, value: float, **kw) -> dict:
    return telemetry("dev_gas_kitchen", "combustible_gas", value, zone_id="zone_kitchen", unit_id="unit_0312",
                     seq=seq, **kw)


async def counts(incident_id: str) -> tuple[int, int]:
    async with SessionLocal() as s:
        events = await s.scalar(select(func.count()).select_from(IncidentEvent)
                                .where(IncidentEvent.incident_id == incident_id))
        snaps = await s.scalar(select(func.count()).select_from(TriangulationSnapshot)
                               .where(TriangulationSnapshot.incident_id == incident_id))
    return events, snaps


async def test_timeline_is_staff_only_and_404s(client):
    assert (await client.get("/api/v1/incidents/nope/evidence-timeline", headers=await headers(client))).status_code == 404
    accepted = await client.post("/api/v1/telemetry", json=gas(1, 6000, edge_state="alarm"))
    incident_id = accepted.json()["incident_id"]
    resident = await client.get(f"/api/v1/incidents/{incident_id}/evidence-timeline",
                                headers=await headers(client, "ana"))
    assert resident.status_code == 403


async def test_motion_and_usual_normal_never_make_an_alarm_benign(client):
    """A room whose frozen normal is already high, with people moving: the items say so, but the
    score, classification and incident state stay those of a critical alarm."""
    now = datetime.now(timezone.utc)
    async with SessionLocal() as s:
        start, end = bl.reference_window(now)
        s.add(ZoneBaseline(building_id="bld_007", zone_id="zone_kitchen", sensor_type="combustible_gas", hour=-1,
                           median=6000.0, mad=500.0, n=999, ref_start=start, ref_end=end, source="seed"))
        s.add(MotionSensor(device_id="espectre-k", zone_id="zone_kitchen", building_id="bld_007", online=True,
                           ready=True, calibrating=False, last_seen_ts=now, last_motion_ts=now))
        await s.commit()
    accepted = await client.post("/api/v1/telemetry", json=gas(1, 6000, edge_state="alarm"))
    assert accepted.json()["incident_state"] == "evacuation"
    incident_id = accepted.json()["incident_id"]
    before = await counts(incident_id)

    body = (await client.get(f"/api/v1/incidents/{incident_id}/fusion", headers=await headers(client))).json()
    assert body["classification"] == "genuine" and body["score"] == 0.0
    assert "critical_or_edge_alarm" in body["active_overrides"]
    items = body["evidence_items"]
    motion = next(i for i in items if i["source"] == "motion")
    assert (motion["status"], motion["role"], motion["strength"]) == ("motion", "context", "weak")
    normal = next(i for i in items if i["source"] == "zone_normal" and i["subject"] == "combustible_gas")
    assert (normal["status"], normal["role"], normal["strength"]) == ("usual", "contradicting", "weak")
    assert all(i["role"] != "contradicting" for i in items if i["source"] != "zone_normal")

    async with SessionLocal() as s:
        assert (await s.get(Incident, incident_id)).state == "evacuation"
    assert await counts(incident_id) == before


async def test_missing_motion_board_is_reported_missing(client):
    accepted = await client.post("/api/v1/telemetry", json=gas(1, 6000, edge_state="alarm"))
    body = (await client.get(f"/api/v1/incidents/{accepted.json()['incident_id']}/fusion",
                             headers=await headers(client))).json()
    motion = [i for i in body["evidence_items"] if i["source"] == "motion"]
    assert motion and all(i["status"] == "no_presence_sensor" and i["role"] == "missing" for i in motion)


async def test_timeline_orders_arrivals_finds_gaps_and_ignores_duplicates(client):
    now = datetime.now(timezone.utc)
    async with SessionLocal() as s:
        incident = Incident(building_id="bld_007", primary_zone_id="zone_kitchen", hazard_type="combustible_gas",
                            state="verification", opened_ts=now - timedelta(minutes=5))
        s.add(incident)
        await s.flush()
        incident_id = incident.id

        def reading(device: str, seq: int, value: float, ago_s: float) -> SensorReading:
            return SensorReading(device_id=device, building_id="bld_007", floor_id="flr_03", unit_id="unit_0312",
                                 zone_id="zone_kitchen", sensor_type="combustible_gas", value=value, units="ppm",
                                 epoch=1, seq=seq, ts=now - timedelta(seconds=ago_s))

        # B crosses first; A crosses later. A's seq 3 lands before seq 2 (out of order) and A then
        # falls silent for 4 minutes (a gap). C never crosses.
        for seq, (value, ago) in enumerate([(100, 300), (100, 290), (3000, 280)], 1):
            s.add(reading("dev_b", seq, value, ago))
        for seq, value, ago in [(1, 100, 300), (3, 2000, 270), (2, 100, 260), (4, 2500, 20)]:
            s.add(reading("dev_a", seq, value, ago))
        s.add(reading("dev_c", 1, 50, 200))
        s.add(TriangulationSnapshot(incident_id=incident_id, ts=now - timedelta(seconds=250),
                                    source_zone_id="zone_kitchen", confidence=0.4, method="nearest"))
        s.add(MotionObservation(device_id="espectre-k", zone_id="zone_kitchen", building_id="bld_007", score=0.9,
                                state="motion", source_ms=1, ready=True, ts=now - timedelta(seconds=100)))
        await s.commit()

    staff = await headers(client)
    url = f"/api/v1/incidents/{incident_id}/evidence-timeline"
    first = await client.get(url, headers=staff)
    assert first.status_code == 200, first.text
    body = first.json()
    devices = {d["device_id"]: d for d in body["devices"]}
    assert [d["device_id"] for d in body["devices"]][:2] == ["dev_b", "dev_a"]
    assert (devices["dev_b"]["order"], devices["dev_a"]["order"], devices["dev_c"]["order"]) == (1, 2, None)
    assert devices["dev_a"]["out_of_order"] == 1
    assert len(devices["dev_a"]["gaps"]) == 1 and devices["dev_a"]["gaps"][0]["seconds"] == 240
    assert devices["dev_b"]["gaps"] == []
    assert [e["method"] for e in body["estimates"]] == ["nearest"]
    assert [m["state"] for m in body["motion"]] == ["motion"]

    # Read-only: a second read is the same (bar "now" closing the open window) and wrote no snapshot.
    again = (await client.get(url, headers=staff)).json()
    assert {**again, "window_end": None} == {**body, "window_end": None}
    async with SessionLocal() as s:
        assert await s.scalar(select(func.count()).select_from(TriangulationSnapshot)
                              .where(TriangulationSnapshot.incident_id == incident_id)) == 1


async def test_duplicate_telemetry_is_one_arrival(client):
    first = await client.post("/api/v1/telemetry", json=gas(5, 6000, edge_state="alarm"))
    incident_id = first.json()["incident_id"]
    await client.post("/api/v1/telemetry", json=gas(5, 6000, edge_state="alarm"))  # redelivery
    await client.post("/api/v1/telemetry", json=gas(4, 6000, edge_state="alarm"))  # late, older seq
    body = (await client.get(f"/api/v1/incidents/{incident_id}/evidence-timeline",
                             headers=await headers(client))).json()
    dev = next(d for d in body["devices"] if d["device_id"] == "dev_gas_kitchen")
    assert dev["sample_count"] == 2 and dev["order"] == 1 and dev["out_of_order"] == 1
