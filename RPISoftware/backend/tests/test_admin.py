"""Admin API: roles and building scope, users (validation, disabled login), floors, units, zones, audit."""

from __future__ import annotations

import json

import pytest
from sqlalchemy import select

from app.db import SessionLocal
from app.ingestion import hardware
from app.ingestion.hardware import handle_hardware_message
from app.models import AuditLogEntry, Building, Floor, ResidentUnit, StaffBuilding, Unit, User
from tests.conftest import auth_token
from tests.hardware_docs import air_doc

USER_KEYS = {"user_id", "username", "display_name", "role", "phone", "email", "active", "units"}


@pytest.fixture(autouse=True)
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _second_building() -> None:
    """bld_008 with its own manager (mara) and resident (vlad)."""
    async with SessionLocal() as s:
        s.add_all([
            Building(id="bld_008", name="Bloc B"),
            Floor(id="flr_b1", building_id="bld_008", level=1, label="Etaj 1"),
            Unit(id="unit_b11", building_id="bld_008", floor_id="flr_b1", label="Ap. 1"),
            User(id="usr_mara", username="mara", display_name="Mara", role="hoa_manager"),
            User(id="usr_vlad", username="vlad", display_name="Vlad", role="resident"),
        ])
        await s.flush()
        s.add_all([StaffBuilding(user_id="usr_mara", building_id="bld_008"),
                   ResidentUnit(user_id="usr_vlad", unit_id="unit_b11", building_id="bld_008")])
        await s.commit()


async def _audit(prefix: str = "admin_") -> list[AuditLogEntry]:
    async with SessionLocal() as s:
        return list((await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action.like(f"{prefix}%")))).all())


async def test_only_admins_and_managers_and_only_their_buildings(client):
    await _second_building()
    for user in ("ana", "dispecer"):
        assert (await client.get("/api/v1/admin/users", headers=await _hdr(client, user))).status_code == 403
    mihai, mara, admin = await _hdr(client, "mihai"), await _hdr(client, "mara"), await _hdr(client, "admin")

    users = (await client.get("/api/v1/admin/users", params={"building_id": "bld_007"}, headers=mihai)).json()
    assert all(set(u) == USER_KEYS for u in users)
    by_name = {u["username"]: u for u in users}
    assert {"ana", "ioana", "radu", "elena", "mihai"} <= set(by_name) and "vlad" not in by_name
    assert by_name["ana"]["units"] == [{"unit_id": "unit_0312", "unit_label": "Ap. 12"}]
    assert by_name["ana"]["active"] is True
    assert {u["username"] for u in (await client.get("/api/v1/admin/users", headers=mara)).json()} == {"mara", "vlad"}
    assert {"vlad", "ana", "admin"} <= {u["username"] for u in (await client.get("/api/v1/admin/users",
                                                                                headers=admin)).json()}
    for url in ("/api/v1/admin/users?building_id=bld_008", "/api/v1/admin/buildings/bld_008/floors",
                "/api/v1/admin/buildings/bld_008/units", "/api/v1/admin/buildings/bld_008/zones",
                "/api/v1/admin/buildings/nope/floors"):
        assert (await client.get(url, headers=mihai)).status_code == 404, url
    assert (await client.get("/api/v1/admin/buildings/bld_008/units", headers=admin)).status_code == 200


async def test_create_users_with_validation_and_role_limits(client):
    await _second_building()
    mihai, admin = await _hdr(client, "mihai"), await _hdr(client, "admin")
    url = "/api/v1/admin/users"

    resp = await client.post(url, headers=mihai, json={
        "username": "dan.p", "display_name": " Dan P ", "role": "resident", "phone": "0722 123 456",
        "email": "dan@example.ro", "unit_ids": ["unit_0313"]})
    assert resp.status_code == 201, resp.text
    dan = resp.json()
    assert (dan["username"], dan["display_name"], dan["phone"], dan["active"], dan["units"]) == (
        "dan.p", "Dan P", "+40722123456", True, [{"unit_id": "unit_0313", "unit_label": "Ap. 13"}])
    assert (await client.post("/api/v1/auth/token", json={"username": "dan.p"})).status_code == 200

    base = {"username": "eva", "display_name": "Eva", "role": "resident"}
    for body, code in (
        ({"username": "dan.p"}, 409), ({"username": "Eva"}, 422), ({"username": "ev"}, 422),
        ({"username": "e" * 33}, 422), ({"phone": "12"}, 422), ({"email": "eva"}, 422), ({"display_name": ""}, 422),
        ({"role": "hoa_manager"}, 403), ({"unit_ids": ["unit_b11"]}, 404), ({"unit_ids": ["common"]}, 422),
        ({"unit_ids": ["nope"]}, 404), ({"extra": 1}, 422),
    ):
        assert (await client.post(url, json={**base, **body}, headers=mihai)).status_code == code, body
    assert (await client.post(url, json={**base, "role": "dispatcher_external", "unit_ids": ["unit_0313"]},
                              headers=admin)).status_code == 422  # staff have no units
    resp = await client.post(url, json={**base, "role": "dispatcher_external"}, headers=admin)
    assert (resp.status_code, resp.json()["role"], resp.json()["units"]) == (201, "dispatcher_external", [])

    [created, _] = await _audit("admin_user_created")
    assert created.actor == "usr_mihai" and created.target == dan["user_id"]
    assert created.detail == {"fields": ["display_name", "email", "phone", "role", "unit_ids", "username"]}
    assert "dan" not in json.dumps(created.detail) and "0722" not in json.dumps(created.detail)


async def test_update_users_and_disabled_accounts_cannot_log_in(client):
    await _second_building()
    mihai, mara, admin = await _hdr(client, "mihai"), await _hdr(client, "mara"), await _hdr(client, "admin")
    url = "/api/v1/admin/users"

    resp = await client.patch(f"{url}/usr_ana", json={"display_name": "Ana P.", "phone": "0744 555 666",
                                                      "unit_ids": ["unit_0312", "unit_0313"]}, headers=mihai)
    assert resp.status_code == 200, resp.text
    assert (resp.json()["display_name"], resp.json()["phone"], [u["unit_id"] for u in resp.json()["units"]]) == (
        "Ana P.", "+40744555666", ["unit_0312", "unit_0313"])
    assert (await client.patch(f"{url}/usr_ana", json={"role": "hoa_manager"}, headers=mihai)).status_code == 403
    assert (await client.patch(f"{url}/usr_mihai", json={"display_name": "M"}, headers=mihai)).status_code == 403
    assert (await client.patch(f"{url}/usr_ana", json={"display_name": "X"}, headers=mara)).status_code == 404
    assert (await client.patch(f"{url}/nope", json={"display_name": "X"}, headers=admin)).status_code == 404
    assert (await client.patch(f"{url}/usr_ana", json={"phone": None}, headers=mihai)).status_code == 422
    assert (await client.patch(f"{url}/usr_ana", json={"username": "x"}, headers=admin)).status_code == 422

    # disabling blocks the dev login with a clear message; enabling restores it
    assert (await client.patch(f"{url}/usr_ana", json={"active": False}, headers=mihai)).json()["active"] is False
    resp = await client.post("/api/v1/auth/token", json={"username": "ana"})
    assert (resp.status_code, resp.json()["detail"]) == (401, "account disabled")
    assert (await client.patch(f"{url}/usr_ana", json={"active": True}, headers=mihai)).status_code == 200
    assert (await client.post("/api/v1/auth/token", json={"username": "ana"})).status_code == 200
    assert (await client.patch(f"{url}/usr_admin", json={"active": False}, headers=admin)).status_code == 409

    # roles: units belong to residents only
    assert (await client.patch(f"{url}/usr_radu", json={"role": "dispatcher_external"},
                               headers=admin)).status_code == 422
    resp = await client.patch(f"{url}/usr_radu", json={"role": "dispatcher_external", "unit_ids": []}, headers=admin)
    assert (resp.status_code, resp.json()["role"], resp.json()["units"]) == (200, "dispatcher_external", [])

    updates = [a.detail for a in await _audit("admin_user_updated")]
    assert updates[0] == {"fields": ["display_name", "phone", "unit_ids"]}
    assert {"fields": ["active"]} in updates and {"fields": ["role", "unit_ids"]} in updates
    assert "Ana P." not in json.dumps(updates)


async def test_floors_units_and_zones(client):
    await _second_building()
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())  # lands in zone_hallway
    mihai = await _hdr(client, "mihai")
    b = "/api/v1/admin/buildings/bld_007"

    assert (await client.get(f"{b}/floors", headers=mihai)).json() == [
        {"floor_id": "flr_03", "label": "Etaj 3", "level": 3}]
    floor = (await client.post(f"{b}/floors", json={"label": "Etaj 4", "level": 4}, headers=mihai)).json()
    assert (floor["label"], floor["level"]) == ("Etaj 4", 4)

    units = {u["unit_id"]: u for u in (await client.get(f"{b}/units", headers=mihai)).json()}
    assert units["unit_0312"] == {"unit_id": "unit_0312", "label": "Ap. 12", "floor_id": "flr_03",
                                  "floor_label": "Etaj 3", "kind": "residential", "residents": 2}
    resp = await client.post(f"{b}/units", json={"label": "Ap. 15", "floor_id": floor["floor_id"],
                                                 "kind": "residential"}, headers=mihai)
    assert resp.status_code == 201 and resp.json()["residents"] == 0 and resp.json()["floor_label"] == "Etaj 4"
    unit = resp.json()
    for body, code in (({"label": "X", "floor_id": "flr_b1", "kind": "common"}, 404),
                       ({"label": "X", "floor_id": "flr_03", "kind": "attic"}, 422)):
        assert (await client.post(f"{b}/units", json=body, headers=mihai)).status_code == code, body
    resp = await client.patch(f"/api/v1/admin/units/{unit['unit_id']}", json={"label": "Ap. 15A"}, headers=mihai)
    assert resp.json()["label"] == "Ap. 15A"
    assert (await client.patch("/api/v1/admin/units/unit_0312", json={"kind": "common"},
                               headers=mihai)).status_code == 409  # still has residents
    assert (await client.patch("/api/v1/admin/units/unit_b11", json={"label": "Y"},
                               headers=mihai)).status_code == 404

    zones = {z["zone_id"]: z for z in (await client.get(f"{b}/zones", headers=mihai)).json()}
    hallway = zones["zone_hallway"]
    assert (hallway["unit_label"], hallway["floor_label"], hallway["kind"]) == ("Spații comune", "Etaj 3", "hallway")
    assert hallway["nodes"] == [{"node_id": "canary", "name": "canary", "kind": "air", "online": True,
                                 "status": "ok"}]
    resp = await client.post(f"{b}/zones", json={"label": "Baie", "kind": "bathroom", "unit_id": unit["unit_id"],
                                                 "pos_x": 1.5, "pos_y": 2}, headers=mihai)
    assert resp.status_code == 201, resp.text
    zone = resp.json()
    assert (zone["floor_id"], zone["floor_label"], zone["unit_label"], zone["nodes"]) == (
        floor["floor_id"], "Etaj 4", "Ap. 15A", [])
    for body, code in (({"label": "X", "kind": "attic", "unit_id": unit["unit_id"]}, 422),
                       ({"label": "X", "kind": "other", "unit_id": "unit_b11"}, 404)):
        assert (await client.post(f"{b}/zones", json=body, headers=mihai)).status_code == code, body
    resp = await client.patch(f"/api/v1/admin/zones/{zone['zone_id']}",
                              json={"label": "Baie mare", "unit_id": "unit_0312", "pos_y": 3}, headers=mihai)
    assert (resp.json()["label"], resp.json()["unit_id"], resp.json()["floor_id"], resp.json()["pos_y"]) == (
        "Baie mare", "unit_0312", "flr_03", 3)

    assert (await client.delete("/api/v1/admin/zones/zone_kitchen", headers=mihai)).status_code == 409  # devices
    assert (await client.delete("/api/v1/admin/zones/zone_hallway", headers=mihai)).status_code == 409  # a node
    assert (await client.delete(f"/api/v1/admin/zones/{zone['zone_id']}", headers=mihai)).status_code == 204
    assert (await client.delete(f"/api/v1/admin/zones/{zone['zone_id']}", headers=mihai)).status_code == 404

    actions = sorted({(a.action, tuple(a.detail["fields"])) for a in await _audit()})
    assert ("admin_zone_updated", ("label", "pos_y", "unit_id")) in actions
    assert {a for a, _ in actions} >= {"admin_floor_created", "admin_unit_created", "admin_unit_updated",
                                       "admin_zone_created", "admin_zone_deleted"}


async def test_delete_an_offline_node_and_let_it_register_again(client):
    from sqlalchemy import func

    from app.models import Device, DeviceCommand, Node, NodeStatus, SensorReading

    await _second_building()
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())
    async with SessionLocal() as s:
        s.add(DeviceCommand(node_id="canary", building_id="bld_007", command="TEST", requested_by_user_id="usr_mihai"))
        await s.commit()
    mihai, url = await _hdr(client, "mihai"), "/api/v1/admin/nodes/canary"

    resp = await client.delete(url, headers=mihai)
    assert (resp.status_code, resp.json()["detail"]) == (409, "node online")
    await handle_hardware_message("canary/availability", b"offline")
    assert (await client.delete(url, headers=await _hdr(client, "mara"))).status_code == 404  # not her building
    assert (await client.delete(url, headers=await _hdr(client, "ana"))).status_code == 403
    assert (await client.delete("/api/v1/admin/nodes/nope", headers=mihai)).status_code == 404
    assert (await client.delete(url, headers=mihai)).status_code == 204

    async def count(model, *where) -> int:
        async with SessionLocal() as s:
            return await s.scalar(select(func.count()).select_from(model).where(*where))

    assert await count(Node, Node.id == "canary") == 0
    assert await count(Device, Device.id.like("canary:%")) == 0
    assert await count(DeviceCommand, DeviceCommand.node_id == "canary") == 0
    assert await count(NodeStatus, NodeStatus.node_id == "canary") >= 1  # raw history kept
    assert await count(SensorReading, SensorReading.device_id == "canary:co") >= 1
    [audit] = await _audit("admin_node_deleted")
    assert (audit.actor, audit.target, audit.detail) == ("usr_mihai", "canary", {"fields": []})
    assert (await client.get("/api/v1/buildings/bld_007/nodes", headers=mihai)).json() == []

    await handle_hardware_message("canary/status", json.dumps(air_doc(uptime_ms=700000)).encode())  # it comes back
    [node] = (await client.get("/api/v1/buildings/bld_007/nodes", headers=mihai)).json()
    assert (node["id"], node["online"], node["zone_id"]) == ("canary", True, "zone_hallway")
    assert await count(Device, Device.id.like("canary:%")) == 5
