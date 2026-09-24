"""Evacuation endpoint used by the Flutter resident app."""

from __future__ import annotations

from tests.conftest import auth_token


async def test_evacuation_returns_routes_and_assembly(client):
    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["building_id"] == "bld_007"
    assert len(data["routes"]) >= 1
    assert len(data["assembly_points"]) >= 1
    route = data["routes"][0]
    assert route["to_assembly_point_id"] == "ap_main"
    assert isinstance(route["path"], list) and route["path"]


async def test_evacuation_requires_auth(client):
    resp = await client.get("/api/v1/buildings/bld_007/evacuation")
    assert resp.status_code in (401, 403)
