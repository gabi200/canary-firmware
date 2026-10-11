"""Technician role (rooms + sensors, no accounts), the new-sensor inbox and "Where are you now?"."""

from __future__ import annotations

import json

import pytest

from app.ingestion import hardware
from app.ingestion.hardware import handle_hardware_message
from tests.conftest import auth_token, telemetry
from tests.hardware_docs import air_doc


@pytest.fixture(autouse=True)
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def test_technician_places_a_new_sensor_but_cannot_touch_accounts(client):
    tech = await _hdr(client, "tehnician")
    assert (await client.get("/api/v1/admin/users", headers=tech)).status_code == 403
    assert (await client.post("/api/v1/admin/users", json={"username": "x", "role": "resident"},
                              headers=tech)).status_code == 403

    zone = await client.post("/api/v1/admin/buildings/bld_007/zones", headers=tech,
                             json={"label": "Cămară", "kind": "other", "unit_id": "unit_0312"})
    assert zone.status_code == 201, zone.text
    zone_id = zone.json()["zone_id"]

    # a sensor that registers itself waits in the inbox (landing zone) until it is placed
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())
    [node] = (await client.get("/api/v1/buildings/bld_007/nodes", headers=tech)).json()
    assert (node["id"], node["zone_id"], node["is_new"]) == ("canary", "zone_hallway", True)

    resp = await client.patch("/api/v1/nodes/canary", json={"zone_id": zone_id}, headers=tech)
    assert resp.status_code == 200, resp.text
    assert (resp.json()["zone_id"], resp.json()["is_new"]) == (zone_id, False)
    [node] = (await client.get("/api/v1/buildings/bld_007/nodes", headers=tech)).json()
    assert node["is_new"] is False
    # its channels follow, so detection uses the new room
    devices = (await client.get("/api/v1/buildings/bld_007/devices", headers=tech)).json()
    assert {d["zone_id"] for d in devices if d["id"].startswith("canary:")} == {zone_id}

    # may run the alarm test (503 here only because tests have no broker)
    assert (await client.post("/api/v1/nodes/canary/commands", json={"command": "TEST"},
                              headers=tech)).status_code == 503


async def test_resident_says_where_they_are_and_the_roster_shows_it(client):
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    incident_id = r.json()["incident_id"]
    ana, url = await _hdr(client, "ana"), f"/api/v1/incidents/{incident_id}/location"

    assert (await client.post(url, json={"location": "attic"}, headers=ana)).status_code == 422
    assert (await client.post(url, json={"location": "home"}, headers=await _hdr(client, "mihai"))).status_code == 403
    assert (await client.post(url, json={"location": "home"}, headers=ana)).status_code == 200
    resp = await client.post(url, json={"location": "outside"}, headers=ana)  # latest answer wins
    assert resp.json()["location"] == "outside"

    roster = (await client.get(f"/api/v1/incidents/{incident_id}/roster", headers=await _hdr(client, "mihai"))).json()
    where = {e["user_id"]: e["location"] for e in roster["entries"]}
    assert where["usr_ana"] == "outside"
    assert where["usr_radu"] is None
