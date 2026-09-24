"""Endpoints backing the React dashboard: zones + readings."""

from __future__ import annotations

from tests.conftest import auth_token, telemetry


async def test_zones_list(client):
    hdr = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    resp = await client.get("/api/v1/buildings/bld_007/zones", headers=hdr)
    assert resp.status_code == 200, resp.text
    zones = resp.json()
    ids = {z["id"] for z in zones}
    assert {"zone_kitchen", "zone_bedroom", "zone_hallway", "zone_boiler"}.issubset(ids)


async def test_readings_list(client):
    hdr = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    # ingest two readings
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 120, zone_id="zone_kitchen", unit_id="unit_0312", seq=1))
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 140, zone_id="zone_kitchen", unit_id="unit_0312", seq=2))

    resp = await client.get("/api/v1/buildings/bld_007/readings",
                            params={"sensor_type": "combustible_gas", "limit": 10}, headers=hdr)
    assert resp.status_code == 200, resp.text
    rows = resp.json()
    assert len(rows) >= 2
    assert rows[0]["sensor_type"] == "combustible_gas"
    assert "ts" in rows[0] and "value" in rows[0]
