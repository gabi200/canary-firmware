"""End-to-end triangulation: the AI estimate can differ from the first-detection zone."""

from __future__ import annotations

from tests.conftest import auth_token, telemetry


async def _hdr(client, user):
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def test_triangulation_overrides_first_detection_zone(client):
    hdr = await _hdr(client, "mihai")

    # 1) low gas first appears in the boiler zone -> incident opens there
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_boiler", "combustible_gas", 1500, zone_id="zone_boiler", unit_id="common", seq=1))
    # 2) a much higher reading in the kitchen -> critical, drives the incident on
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    incident_id = r.json()["incident_id"]

    # incident's first-detection zone is the boiler...
    inc = (await client.get(f"/api/v1/incidents/{incident_id}", headers=hdr)).json()
    assert inc["primary_zone_id"] == "zone_boiler"
    # ...but triangulation localizes the source to the kitchen (highest concentration)
    assert inc["est_source_zone_id"] == "zone_kitchen"
    assert inc["triangulation_confidence"] is not None and inc["triangulation_confidence"] > 0

    tri = (await client.get(f"/api/v1/incidents/{incident_id}/triangulation", headers=hdr)).json()
    assert tri["source_zone_id"] == "zone_kitchen"
    assert tri["n_contributors"] >= 2
    assert "centroid" in tri["method"]
    assert tri["contributors"][0]["device_id"] == "dev_gas_kitchen"


async def test_triangulation_requires_role(client):
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    incs = (await client.get(
        "/api/v1/buildings/bld_007/incidents?active=true",
        headers=await _hdr(client, "mihai"))).json()
    iid = incs[0]["id"]
    # resident cannot read triangulation
    resp = await client.get(f"/api/v1/incidents/{iid}/triangulation", headers=await _hdr(client, "ana"))
    assert resp.status_code == 403
