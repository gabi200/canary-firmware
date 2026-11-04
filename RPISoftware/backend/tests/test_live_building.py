"""Demo building (bld_007) and the real Canary Live building (bld_live)."""

from __future__ import annotations

from sqlalchemy import delete, func, select

from app.db import SessionLocal
from app.models import Building, Device, Floor, Node, ResidentUnit, StaffBuilding, Unit, Zone
from app.seed import ensure_live_building
from tests.conftest import auth_token


async def _hdr(client, username):
    return {"Authorization": f"Bearer {await auth_token(client, username)}"}


async def _drop_live(session) -> None:
    for model in (StaffBuilding, ResidentUnit, Zone, Unit, Floor):
        await session.execute(delete(model).where(model.building_id == "bld_live"))
    await session.execute(delete(Building).where(Building.id == "bld_live"))
    await session.commit()


def _node(node_id: str, base: str, kind: str = "air") -> Node:
    return Node(id=node_id, kind=kind, mqtt_base=base, name=node_id, firmware="t",
                building_id="bld_007", zone_id="zone_hallway", online=True, boot_epoch=1)


def _device(node_id: str) -> Device:
    return Device(id=f"{node_id}:co", building_id="bld_007", floor_id="flr_03", unit_id="common",
                  zone_id="zone_hallway", sensor_type="co")


async def test_seed_creates_both_buildings(client):
    hdr = await _hdr(client, "mihai")
    live = await client.get("/api/v1/buildings/bld_live", headers=hdr)
    assert live.status_code == 200, live.text
    assert live.json()["name"] == "Canary Live"
    demo = await client.get("/api/v1/buildings/bld_007", headers=hdr)
    assert demo.json()["name"] == "Demo"
    zones = await client.get("/api/v1/buildings/bld_live/zones", headers=hdr)
    assert [z["id"] for z in zones.json()] == ["zone_live"]


async def test_existing_real_nodes_move_to_live(client):
    async with SessionLocal() as session:
        await _drop_live(session)
        session.add_all([_node("canary", "canary"), _node("air-sensor", "air_sensor")])
        await session.flush()
        session.add_all([_device("canary"), _device("air-sensor")])
        await session.commit()
        await ensure_live_building(session)

        canary = await session.get(Node, "canary")
        assert (canary.building_id, canary.zone_id) == ("bld_live", "zone_live")
        dev = await session.get(Device, "canary:co")
        assert (dev.building_id, dev.zone_id) == ("bld_live", "zone_live")
        other = await session.get(Node, "air-sensor")
        assert (other.building_id, other.zone_id) == ("bld_007", "zone_hallway")


async def test_ensure_live_building_idempotent(client):
    async with SessionLocal() as session:
        await _drop_live(session)
        session.add(_node("canary", "canary"))
        await session.commit()
        await ensure_live_building(session)
        node = await session.get(Node, "canary")
        node.building_id, node.zone_id = "bld_007", "zone_hallway"
        await session.commit()

        await ensure_live_building(session)
        await session.refresh(node)
        assert (node.building_id, node.zone_id) == ("bld_007", "zone_hallway")
        for model, expected in ((StaffBuilding, 1), (ResidentUnit, 4)):
            n = await session.scalar(
                select(func.count()).select_from(model).where(model.building_id == "bld_live"))
            assert n == expected, model


async def test_resident_sees_live_building(client):
    resp = await client.get("/api/v1/buildings/bld_live/summary", headers=await _hdr(client, "ana"))
    assert resp.status_code == 200, resp.text
