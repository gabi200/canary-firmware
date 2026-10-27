"""Water-leak impact map: explicit topology, below / riser reach, visible missing or broken
configuration, and that it never changes the incident."""

from __future__ import annotations

import json

import pytest
from sqlalchemy import func, select

from app.analytics.water_impact import BuildingTopology, affected_units, parse_topology
from app.config import settings
from app.db import SessionLocal
from app.models import Incident, IncidentEvent
from tests.conftest import auth_token, telemetry

TOPOLOGY = {"buildings": {"bld_007": {
    "below": {"unit_0312": ["unit_0212"], "unit_0212": ["unit_0112"], "unit_0313": ["unit_0213"]},
    "risers": {"riser_A": ["unit_0112", "unit_0212", "unit_0312", "unit_0412"]},
}}}


def test_below_chain_then_riser():
    topo = parse_topology(TOPOLOGY)["bld_007"]
    out = [(i.unit_id, i.reason, i.hops, i.riser) for i in affected_units(topo, {"unit_0312"})]
    assert out == [("unit_0212", "below", 1, "riser_A"), ("unit_0112", "below", 2, "riser_A"),
                   ("unit_0412", "riser", None, "riser_A")]


def test_unit_without_topology_reaches_nothing():
    assert affected_units(parse_topology(TOPOLOGY)["bld_007"], {"unit_0314"}) == []


def test_cycles_and_duplicates_are_harmless():
    topo = BuildingTopology(below={"a": ["b", "b"], "b": ["a", "c"], "c": ["a"]}, risers={"r": ["a", "a", "c"]})
    assert [(i.unit_id, i.hops) for i in affected_units(topo, {"a"})] == [("b", 1), ("c", 2)]


def test_two_leaking_units_are_not_listed_as_affected():
    topo = parse_topology(TOPOLOGY)["bld_007"]
    units = {i.unit_id for i in affected_units(topo, {"unit_0312", "unit_0212"})}
    assert "unit_0212" not in units and "unit_0112" in units


@pytest.mark.parametrize("doc", [[], {"buildings": []}, {"buildings": {"b": {"below": {"u": "x"}}}},
                                 {"buildings": {"b": {"risers": {"r": [1]}}}}])
def test_malformed_topology_is_rejected(doc):
    assert parse_topology(doc) is None


async def _leak(client) -> str:
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_leak_kitchen", "water_leak", 1.0, zone_id="zone_kitchen", unit_id="unit_0312", units="bool",
        edge_state="alarm"))
    assert resp.status_code == 200, resp.text
    return resp.json()["incident_id"]


async def _impact(client, incident_id: str, user="mihai"):
    token = await auth_token(client, user)
    return await client.get(f"/api/v1/incidents/{incident_id}/water-impact", headers={"Authorization": f"Bearer {token}"})


async def test_endpoint_lists_units_below_and_on_riser(client, tmp_path, monkeypatch):
    path = tmp_path / "topology.json"
    path.write_text(json.dumps(TOPOLOGY))
    monkeypatch.setattr(settings, "water_topology_file", str(path))
    body = (await _impact(client, await _leak(client))).json()
    assert body["applicable"] and body["topology"] == "configured"
    assert [(u["unit_id"], u["label"]) for u in body["leaking_units"]] == [("unit_0312", "Ap. 12")]
    assert [(u["unit_id"], u["reason"], u["hops"]) for u in body["affected"]] == [
        ("unit_0212", "below", 1), ("unit_0112", "below", 2), ("unit_0412", "riser", None)]


async def test_missing_or_broken_topology_is_visible(client, tmp_path, monkeypatch):
    incident_id = await _leak(client)
    monkeypatch.setattr(settings, "water_topology_file", "")
    body = (await _impact(client, incident_id)).json()
    assert body["topology"] == "not_configured" and body["affected"] == []
    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    monkeypatch.setattr(settings, "water_topology_file", str(bad))
    assert (await _impact(client, incident_id)).json()["topology"] == "invalid"
    other = tmp_path / "other.json"
    other.write_text(json.dumps({"buildings": {"bld_999": {}}}))
    monkeypatch.setattr(settings, "water_topology_file", str(other))
    assert (await _impact(client, incident_id)).json()["topology"] == "not_configured"


async def test_not_applicable_to_other_hazards(client):
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312"))
    body = (await _impact(client, resp.json()["incident_id"])).json()
    assert body["applicable"] is False and body["affected"] == []


async def test_roles_and_404(client):
    incident_id = await _leak(client)
    assert (await _impact(client, incident_id, "ana")).status_code == 403
    assert (await _impact(client, incident_id, "dispecer")).status_code == 200
    assert (await _impact(client, "nope")).status_code == 404


async def test_alarm_regression_impact_map_changes_nothing(client, tmp_path, monkeypatch):
    path = tmp_path / "topology.json"
    path.write_text(json.dumps(TOPOLOGY))
    monkeypatch.setattr(settings, "water_topology_file", str(path))
    incident_id = await _leak(client)
    async with SessionLocal() as s:
        before = (await s.get(Incident, incident_id)).state
        events = await s.scalar(select(func.count()).select_from(IncidentEvent))
    for _ in range(2):
        assert (await _impact(client, incident_id)).status_code == 200
    async with SessionLocal() as s:
        assert (await s.get(Incident, incident_id)).state == before != "normal"
        assert await s.scalar(select(func.count()).select_from(IncidentEvent)) == events
