"""Dispatchers never get raw presence outside an open incident (aggregates stay); zone labels."""

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


async def test_dispatchers_get_no_raw_presence(client):
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())
    dispecer, mihai = await _hdr(client, "dispecer"), await _hdr(client, "mihai")
    history = "/api/v1/nodes/canary/history"

    resp = await client.get(history, headers=dispecer)
    assert resp.status_code == 200 and "presence.detected" not in resp.json()["fields"]
    assert "co.ppm" in resp.json()["fields"]
    for fields in ("presence.detected", "co.ppm,presence.stationary_distance_cm", "presence"):
        assert (await client.get(history, params={"fields": fields}, headers=dispecer)).status_code == 403, fields
    assert "presence.detected" in (await client.get(history, headers=mihai)).json()["fields"]

    [node] = (await client.get("/api/v1/buildings/bld_007/nodes", headers=dispecer)).json()
    assert "presence" not in node["status"] and "co" in node["status"]
    [node] = (await client.get("/api/v1/buildings/bld_007/nodes", headers=mihai)).json()
    assert node["status"]["presence"]["detected"] is True

    # aggregates stay available (life-safety)
    assert (await client.get("/api/v1/buildings/bld_007/occupancy", headers=dispecer)).status_code == 200


async def test_dispatcher_readings_include_presence_only_during_an_open_incident(client):
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())
    dispecer, mihai = await _hdr(client, "dispecer"), await _hdr(client, "mihai")
    url = "/api/v1/buildings/bld_007/readings"

    def types(resp) -> set[str]:
        return {r["sensor_type"] for r in resp.json()}

    assert "radar_presence" not in types(await client.get(url, headers=dispecer))
    assert (await client.get(url, params={"sensor_type": "radar_presence"}, headers=dispecer)).json() == []
    assert "radar_presence" in types(await client.get(url, headers=mihai))

    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    assert "radar_presence" in types(await client.get(url, headers=dispecer))


async def test_zones_carry_unit_and_floor_labels(client):
    zones = (await client.get("/api/v1/buildings/bld_007/zones", headers=await _hdr(client, "mihai"))).json()
    by_id = {z["id"]: z for z in zones}
    assert (by_id["zone_kitchen"]["unit_label"], by_id["zone_kitchen"]["floor_label"]) == ("Ap. 12", "Etaj 3")
    assert (by_id["zone_hallway"]["unit_label"], by_id["zone_hallway"]["floor_label"]) == ("Spații comune", "Etaj 3")
    assert by_id["zone_kitchen"]["floor_id"] == "flr_03"  # existing fields unchanged
