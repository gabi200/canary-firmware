"""Triangulation history: distinct estimates persisted, listed oldest first, thinned, pruned."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.db import SessionLocal
from app.models import TriangulationSnapshot
from app.retention import prune_old_rows
from tests.conftest import auth_token, telemetry

SNAPSHOT_KEYS = {"ts", "source_zone_id", "source_x", "source_y", "confidence", "method", "n_contributors",
                 "airflow_applied", "contributors"}


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _gas_incident(client) -> str:
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_boiler", "combustible_gas", 1500, zone_id="zone_boiler", unit_id="common", seq=1))
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    return resp.json()["incident_id"]


async def test_distinct_estimates_are_kept_oldest_first(client):
    incident_id = await _gas_incident(client)
    mihai = await _hdr(client, "mihai")
    url = f"/api/v1/incidents/{incident_id}/triangulation/history"

    first = (await client.get(url, headers=mihai)).json()
    assert first["incident_id"] == incident_id and len(first["snapshots"]) >= 1
    snap = first["snapshots"][-1]
    assert set(snap) == SNAPSHOT_KEYS and snap["source_zone_id"] == "zone_kitchen"
    assert set(snap["contributors"][0]) == {"device_id", "zone_id", "value", "weight"}

    # recomputing the same estimate adds nothing; a new reading that moves it adds one
    await client.get(f"/api/v1/incidents/{incident_id}/triangulation", headers=mihai)
    assert len((await client.get(url, headers=mihai)).json()["snapshots"]) == len(first["snapshots"])
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_boiler", "combustible_gas", 5000, zone_id="zone_boiler", unit_id="common", seq=3,
        edge_state="alarm"))
    await client.get(f"/api/v1/incidents/{incident_id}/triangulation", headers=mihai)
    later = (await client.get(url, headers=await _hdr(client, "dispecer"))).json()["snapshots"]
    assert len(later) > len(first["snapshots"])
    assert [s["ts"] for s in later] == sorted(s["ts"] for s in later)
    assert later[0] == first["snapshots"][0]

    assert (await client.get(url, headers=await _hdr(client, "ana"))).status_code == 403
    assert (await client.get("/api/v1/incidents/nope/triangulation/history", headers=mihai)).status_code == 404


async def test_long_history_is_thinned_to_500_and_old_snapshots_are_pruned(client):
    incident_id = await _gas_incident(client)
    now = datetime.now(timezone.utc)
    async with SessionLocal() as s:
        for i in range(600):
            s.add(TriangulationSnapshot(incident_id=incident_id, ts=now - timedelta(days=20) + timedelta(seconds=i),
                                        source_zone_id="zone_boiler", confidence=i / 1000, method="test",
                                        n_contributors=1, contributors=[]))
        await s.commit()
    snapshots = (await client.get(f"/api/v1/incidents/{incident_id}/triangulation/history",
                                  headers=await _hdr(client, "mihai"))).json()["snapshots"]
    assert len(snapshots) == 500
    assert snapshots[0]["confidence"] == 0 and snapshots[-1]["source_zone_id"] == "zone_kitchen"  # first + last
    assert [s["ts"] for s in snapshots] == sorted(s["ts"] for s in snapshots)

    deleted = await prune_old_rows()  # 14-day retention: the 600 old ones go, the live estimate stays
    assert deleted["triangulation_snapshots"] == 600
    left = (await client.get(f"/api/v1/incidents/{incident_id}/triangulation/history",
                             headers=await _hdr(client, "mihai"))).json()["snapshots"]
    assert [s["source_zone_id"] for s in left][-1] == "zone_kitchen" and len(left) < 10
