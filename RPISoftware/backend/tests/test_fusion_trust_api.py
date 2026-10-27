"""F3a fusion explanation and F1 on-demand trust endpoints."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select

from app.db import SessionLocal
from app.models import Device, Incident, IncidentEvent, Node, SensorReading
from tests.conftest import auth_token, telemetry


async def headers(client, username: str = "mihai") -> dict[str, str]:
    return {"Authorization": f"Bearer {await auth_token(client, username)}"}


async def test_new_endpoints_are_staff_only(client):
    resident = await headers(client, "ana")
    trust = await client.get("/api/v1/buildings/bld_007/sensor-trust", headers=resident)
    assert trust.status_code == 403

    async with SessionLocal() as session:
        incident = Incident(building_id="bld_007", primary_zone_id="zone_kitchen",
                            hazard_type="particulate", state="detection")
        session.add(incident)
        await session.commit()
        incident_id = incident.id
    fusion = await client.get(f"/api/v1/incidents/{incident_id}/fusion", headers=resident)
    assert fusion.status_code == 403


async def test_trust_endpoint_uses_bounded_history_and_reports_baseline_shift(client):
    now = datetime.now(timezone.utc)
    async with SessionLocal() as session:
        session.add(Node(id="trust-air", kind="air", mqtt_base="trust/air", name="Trust air",
                         firmware="test", building_id="bld_007", zone_id="zone_kitchen",
                         online=True, last_seen_ts=now, last_uptime_ms=1, boot_epoch=1))
        session.add(Device(id="trust-air:co", building_id="bld_007", floor_id="flr_03",
                           unit_id="unit_0312", zone_id="zone_kitchen", sensor_type="co",
                           last_seen_ts=now))
        for i in range(8):
            session.add(SensorReading(
                device_id="trust-air:co", building_id="bld_007", floor_id="flr_03",
                unit_id="unit_0312", zone_id="zone_kitchen", sensor_type="co",
                value=10 + i % 2, units="ppm", epoch=1, seq=i,
                ts=now - timedelta(hours=4, minutes=-i),
            ))
        for i in range(6):
            session.add(SensorReading(
                device_id="trust-air:co", building_id="bld_007", floor_id="flr_03",
                unit_id="unit_0312", zone_id="zone_kitchen", sensor_type="co",
                value=40 + i % 2, units="ppm", epoch=1, seq=100 + i,
                ts=now - timedelta(minutes=30 - i),
            ))
        # Older than the endpoint's maximum window: must not become the reference.
        session.add(SensorReading(
            device_id="trust-air:co", building_id="bld_007", floor_id="flr_03",
            unit_id="unit_0312", zone_id="zone_kitchen", sensor_type="co",
            value=999, units="ppm", epoch=1, seq=999,
            ts=now - timedelta(days=10),
        ))
        await session.commit()

    response = await client.get(
        "/api/v1/buildings/bld_007/sensor-trust?hours=24", headers=await headers(client)
    )
    assert response.status_code == 200, response.text
    trust = next(item for item in response.json() if item["node_id"] == "trust-air")
    assert (trust["state"], trust["reason"]) == ("suspect", "baseline_shift_cause_unknown")
    assert trust["channels"][0]["sample_count"] == 14


async def test_pm_channels_from_one_instrument_are_one_fresh_witness(client):
    now = datetime.now(timezone.utc)
    async with SessionLocal() as session:
        incident = Incident(
            building_id="bld_007", primary_zone_id="zone_kitchen", hazard_type="particulate",
            state="verification", benign_score=0.99, distinct_device_ids=["old-device"],
        )
        session.add(incident)
        await session.flush()
        for i, channel in enumerate(("pm1_0", "pm2_5", "pm10")):
            session.add(SensorReading(
                device_id=f"air-one:{channel}", building_id="bld_007", floor_id="flr_03",
                unit_id="unit_0312", zone_id="zone_kitchen", sensor_type="particulate",
                value=80, units="ug/m3", edge_state="warn", epoch=1, seq=i,
                ts=now - timedelta(seconds=10 - i),
            ))
        await session.commit()
        incident_id = incident.id

    response = await client.get(f"/api/v1/incidents/{incident_id}/fusion", headers=await headers(client))
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["fresh_witnesses"] == 1
    assert body["score"] != 0.99  # recomputed now; never the incident's possibly-stale stored score
    assert "co" in body["missing_inputs"]
    assert body["inputs"][0]["age_seconds"] >= 0


async def test_advisory_reads_do_not_change_alarm_or_events(client):
    critical = telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000,
        zone_id="zone_kitchen", unit_id="unit_0312", seq=77, edge_state="alarm",
    )
    accepted = await client.post("/api/v1/telemetry", json=critical)
    assert accepted.json()["incident_state"] == "evacuation"
    incident_id = accepted.json()["incident_id"]

    async with SessionLocal() as session:
        before = await session.scalar(
            select(func.count()).select_from(IncidentEvent).where(IncidentEvent.incident_id == incident_id)
        )

    staff = await headers(client)
    fusion = await client.get(f"/api/v1/incidents/{incident_id}/fusion", headers=staff)
    trust = await client.get("/api/v1/buildings/bld_007/sensor-trust", headers=staff)
    assert (fusion.status_code, trust.status_code) == (200, 200)

    async with SessionLocal() as session:
        incident = await session.get(Incident, incident_id)
        after = await session.scalar(
            select(func.count()).select_from(IncidentEvent).where(IncidentEvent.incident_id == incident_id)
        )
    assert incident is not None and incident.state == "evacuation"
    assert after == before
