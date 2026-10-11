"""Evacuation endpoint used by the Flutter resident app."""

from __future__ import annotations

from tests.conftest import auth_token

from app.db import SessionLocal
from app.models import AssemblyPoint, EvacuationRoute, Floor


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


async def test_evacuation_resolves_mixed_waypoints_to_human_readable_values(client):
    """A route's stored JSON must never expose dict waypoints through its id-only path."""
    async with SessionLocal() as session:
        route = await session.get(EvacuationRoute, "er_flr03")
        assert route is not None
        route.path = [
            "zone_hallway",
            {
                "id": "stairwell_main",
                "label": "Scara principala",
                "kind": "stairwell",
                "hint": "Coborati pana la parter.",
            },
            {"id": "exit_front", "label": "Iesirea din fata", "kind": "exit"},
            "ap_main",
            "exit_rear",
        ]
        await session.commit()

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)

    assert resp.status_code == 200, resp.text
    route = resp.json()["routes"][0]
    assert route["path"] == ["zone_hallway", "stairwell_main", "exit_front", "ap_main", "exit_rear"]
    assert route["waypoints"] == [
        {"id": "zone_hallway", "label": "Hol scară", "kind": "hallway", "hint": ""},
        {
            "id": "stairwell_main",
            "label": "Scara principala",
            "kind": "stairwell",
            "hint": "Coborati pana la parter.",
        },
        {"id": "exit_front", "label": "Iesirea din fata", "kind": "exit", "hint": ""},
        {"id": "ap_main", "label": "Punct adunare - parcare fata", "kind": "assembly_point", "hint": ""},
        {"id": "exit_rear", "label": "Exit rear", "kind": "waypoint", "hint": ""},
    ]


async def test_evacuation_skips_dict_waypoint_without_string_id(client):
    async with SessionLocal() as session:
        route = await session.get(EvacuationRoute, "er_flr03")
        assert route is not None
        route.path = [{"label": "Missing id"}, "zone_hallway"]
        await session.commit()

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)

    assert resp.status_code == 200, resp.text
    route = resp.json()["routes"][0]
    assert route["path"] == ["zone_hallway"]
    assert route["waypoints"] == [{"id": "zone_hallway", "label": "Hol scară", "kind": "hallway", "hint": ""}]


async def test_evacuation_skips_non_string_non_dict_waypoint(client):
    async with SessionLocal() as session:
        route = await session.get(EvacuationRoute, "er_flr03")
        assert route is not None
        route.path = [17, "zone_hallway"]
        await session.commit()

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)

    assert resp.status_code == 200, resp.text
    assert resp.json()["routes"][0]["path"] == ["zone_hallway"]


async def test_evacuation_returns_empty_route_when_every_waypoint_is_invalid(client):
    async with SessionLocal() as session:
        route = await session.get(EvacuationRoute, "er_flr03")
        assert route is not None
        route.path = [{"label": "Missing id"}, 17, None]
        await session.commit()

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)

    assert resp.status_code == 200, resp.text
    route = resp.json()["routes"][0]
    assert route["path"] == []
    assert route["waypoints"] == []


async def test_evacuation_orders_routes_by_floor_and_id(client):
    async with SessionLocal() as session:
        session.add(Floor(id="flr_02", building_id="bld_007", level=2, label="Etaj 2"))
        session.add_all(
            [
                EvacuationRoute(
                    id="er_floor_02",
                    building_id="bld_007",
                    floor_id="flr_02",
                    to_assembly_point_id="ap_main",
                    path=[],
                ),
                EvacuationRoute(
                    id="er_z",
                    building_id="bld_007",
                    floor_id="flr_03",
                    to_assembly_point_id="ap_main",
                    path=[],
                ),
                EvacuationRoute(
                    id="er_a",
                    building_id="bld_007",
                    floor_id="flr_03",
                    to_assembly_point_id="ap_main",
                    path=[],
                ),
            ]
        )
        await session.commit()

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)

    assert resp.status_code == 200, resp.text
    assert [route["id"] for route in resp.json()["routes"]] == ["er_floor_02", "er_a", "er_flr03", "er_z"]


async def test_evacuation_orders_assembly_points_by_id(client):
    async with SessionLocal() as session:
        session.add_all(
            [
                AssemblyPoint(id="ap_z", building_id="bld_007", label="Z"),
                AssemblyPoint(id="ap_a", building_id="bld_007", label="A"),
            ]
        )
        await session.commit()

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    resp = await client.get("/api/v1/buildings/bld_007/evacuation", headers=hdr)

    assert resp.status_code == 200, resp.text
    assert [point["id"] for point in resp.json()["assembly_points"]] == ["ap_a", "ap_main", "ap_z"]


async def test_evacuation_requires_auth(client):
    resp = await client.get("/api/v1/buildings/bld_007/evacuation")
    assert resp.status_code in (401, 403)
