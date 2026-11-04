"""Device commands: topics/payloads like the firmware, roles, validation, rate limit, results, timeout."""

from __future__ import annotations

import json
from datetime import timedelta

import pytest
from sqlalchemy import select

from app.db import SessionLocal
from app.ingestion import broker, hardware
from app.ingestion.hardware import handle_hardware_message
from app.ingestion.mqtt import dispatch
from app.models import Building, DeviceCommand, StaffBuilding, User
from app.realtime.ws import manager
from tests.conftest import auth_token
from tests.hardware_docs import air_doc, water_doc

ITEM_KEYS = {"command_id", "command", "status", "detail", "requested_by_name", "sent_ts", "result_ts"}


class FakeMqtt:
    def __init__(self) -> None:
        self.published: list[tuple[str, str, int, bool]] = []

    async def publish(self, topic: str, payload: str, *, qos: int = 0, retain: bool = False) -> None:
        self.published.append((topic, payload, qos, retain))


@pytest.fixture(autouse=True)
def mqtt(monkeypatch):
    hardware.reset_state()
    fake = FakeMqtt()
    monkeypatch.setattr(broker, "client", fake)
    yield fake
    hardware.reset_state()


@pytest.fixture
def ws_events(monkeypatch) -> list[dict]:
    events: list[dict] = []

    async def capture(building_id: str, message: dict) -> None:
        events.append(message)

    monkeypatch.setattr(manager, "broadcast", capture)
    return events


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _nodes() -> None:
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())
    await handle_hardware_message("water-sensor/status", json.dumps(water_doc()).encode())


async def _age_commands(seconds: float) -> None:
    """Move every command `seconds` into the past (rate limit / timeout tests)."""
    async with SessionLocal() as s:
        for row in (await s.scalars(select(DeviceCommand))).all():
            row.sent_ts -= timedelta(seconds=seconds)
        await s.commit()


async def _send(client, node: str, command: str, user: str = "mihai"):
    return await client.post(f"/api/v1/nodes/{node}/commands", json={"command": command},
                             headers=await _hdr(client, user))


async def test_commands_publish_like_the_firmware_and_are_validated(client, mqtt):
    await _nodes()
    resp = await _send(client, "canary", "TEST")
    assert resp.status_code == 202, resp.text
    body = resp.json()
    assert set(body) == {"command_id", "node_id", "command", "status", "sent_ts"}
    assert (body["node_id"], body["command"], body["status"]) == ("canary", "TEST", "sent")
    assert mqtt.published == [("canary/buzzer/set", "TEST", 1, False)]

    assert (await _send(client, "canary", "SILENCE")).status_code == 429  # < 3 s after the last one
    await _age_commands(5)
    assert (await _send(client, "canary", "SILENCE")).status_code == 202
    for command in ("OPEN", "CLOSE"):
        assert (await _send(client, "canary", command)).status_code == 422, command
    assert (await _send(client, "water-sensor", "TEST")).status_code == 422
    assert (await _send(client, "canary", "test")).status_code == 422
    for command, topic in (("CLOSE", "water-sensor/valve/set"), ("OPEN", "water-sensor/valve/set"),
                           ("SILENCE", "water-sensor/buzzer/set")):
        await _age_commands(5)
        assert (await _send(client, "water-sensor", command)).status_code == 202
        assert mqtt.published[-1] == (topic, command, 1, False)
    assert len(mqtt.published) == 5  # refused requests publish nothing

    await handle_hardware_message("water-sensor/availability", b"offline")
    await _age_commands(5)
    assert (await _send(client, "water-sensor", "OPEN")).status_code == 409
    assert (await _send(client, "nope", "TEST")).status_code == 404


async def test_broker_down_is_503(client, monkeypatch):
    await _nodes()
    monkeypatch.setattr(broker, "client", None)
    resp = await _send(client, "canary", "TEST")
    assert resp.status_code == 503 and "MQTT" in resp.json()["detail"]


async def test_roles_and_scope(client):
    await _nodes()
    assert (await _send(client, "canary", "TEST", "dispecer")).status_code == 403
    assert (await _send(client, "canary", "TEST", "ana")).status_code == 404  # hallway: a common area
    async with SessionLocal() as s:  # a manager of another building only
        s.add_all([Building(id="bld_008", name="Bloc B"), User(id="usr_mara", username="mara", role="hoa_manager")])
        await s.flush()
        s.add(StaffBuilding(user_id="usr_mara", building_id="bld_008"))
        await s.commit()
    assert (await _send(client, "canary", "TEST", "mara")).status_code == 404
    assert (await client.get("/api/v1/nodes/canary/commands", headers=await _hdr(client, "mara"))).status_code == 404

    mihai = await _hdr(client, "mihai")
    await client.patch("/api/v1/nodes/water-sensor", json={"zone_id": "zone_kitchen"}, headers=mihai)  # Ap. 12
    assert (await _send(client, "water-sensor", "CLOSE", "radu")).status_code == 404  # not his flat
    assert (await _send(client, "water-sensor", "CLOSE", "ana")).status_code == 202
    await _age_commands(5)
    assert (await _send(client, "canary", "TEST", "admin")).status_code == 202
    assert (await _send(client, "water-sensor", "OPEN", "admin")).status_code == 202
    items = (await client.get("/api/v1/nodes/water-sensor/commands", headers=await _hdr(client, "ana"))).json()
    # a resident sees who sent a command only for their own ones
    assert [(i["command"], i["requested_by_name"]) for i in items] == [("OPEN", None), ("CLOSE", "Ana Popescu")]
    items = (await client.get("/api/v1/nodes/water-sensor/commands", headers=mihai)).json()
    assert [i["requested_by_name"] for i in items] == ["System Admin", "Ana Popescu"]
    assert (await client.get("/api/v1/nodes/canary/commands",
                             headers=await _hdr(client, "dispecer"))).status_code == 403


async def test_results_match_the_latest_command_and_broadcast(client, ws_events):
    await _nodes()
    first = (await _send(client, "canary", "TEST")).json()
    await dispatch("canary/command/result", b'{"command":"TEST","accepted":true,"state":"self_test"}')
    [event] = [e for e in ws_events if e.get("type") == "command_result"]
    assert set(event) == {"type", "building_id", "node_id", "command_id", "command", "status", "detail", "ts"}
    assert (event["building_id"], event["node_id"], event["command_id"], event["status"], event["detail"]) == (
        "bld_007", "canary", first["command_id"], "accepted", "self_test")

    await _age_commands(5)
    second = (await _send(client, "canary", "SILENCE")).json()
    await dispatch("canary/command/result", b'{"command":"TEST","accepted":true,"state":"self_test"}')  # no match
    await dispatch("canary/command/result", b'{"command":"SILENCE","accepted":false,"error":"alarm_inactive"}',
                   retain=True)  # retained: stale, ignored
    await dispatch("canary/command/result", b"not json")
    await dispatch("canary/command/result", b'{"command":"SILENCE","accepted":false,"error":"alarm_inactive"}')
    items = (await client.get("/api/v1/nodes/canary/commands", headers=await _hdr(client, "mihai"))).json()
    assert all(set(i) == ITEM_KEYS for i in items)
    assert [(i["command_id"], i["status"], i["detail"], i["requested_by_name"]) for i in items] == [
        (second["command_id"], "rejected", "alarm_inactive", "Mihai (administrator)"),
        (first["command_id"], "accepted", "self_test", "Mihai (administrator)"),
    ]
    assert all(i["result_ts"] for i in items)


async def test_unanswered_commands_time_out_and_late_answers_still_land(client):
    await _nodes()
    sent = (await _send(client, "canary", "TEST")).json()
    await _age_commands(20)
    url = "/api/v1/nodes/canary/commands"
    mihai = await _hdr(client, "mihai")
    assert (await client.get(url, headers=mihai)).json()[0]["status"] == "timeout"
    await dispatch("canary/command/result", b'{"command":"TEST","accepted":true,"state":"self_test"}')  # 20 s: lands
    assert (await client.get(url, headers=mihai)).json()[0]["status"] == "accepted"

    later = (await _send(client, "canary", "TEST")).json()
    await _age_commands(40)
    await dispatch("canary/command/result", b'{"command":"TEST","accepted":true,"state":"self_test"}')  # too late
    items = (await client.get(url, params={"limit": 1}, headers=mihai)).json()
    assert [(i["command_id"], i["status"], i["result_ts"]) for i in items] == [(later["command_id"], "timeout", None)]
    assert sent["command_id"] != later["command_id"]


async def test_last_command_on_nodes_and_summary(client):
    await _nodes()
    mihai, ana = await _hdr(client, "mihai"), await _hdr(client, "ana")
    sent = (await _send(client, "canary", "TEST")).json()
    await dispatch("canary/command/result", b'{"command":"TEST","accepted":true,"state":"self_test"}')

    nodes = {n["id"]: n for n in (await client.get("/api/v1/buildings/bld_007/nodes", headers=mihai)).json()}
    assert nodes["water-sensor"]["last_command"] is None
    last = nodes["canary"]["last_command"]
    assert set(last) == ITEM_KEYS and (last["command_id"], last["status"]) == (sent["command_id"], "accepted")

    summary = (await client.get("/api/v1/buildings/bld_007/summary", headers=mihai)).json()
    by_id = {n["node_id"]: n for z in summary["zones"] for n in z["nodes"]}
    assert by_id["canary"]["last_command"]["requested_by_name"] == "Mihai (administrator)"
    resident = (await client.get("/api/v1/buildings/bld_007/summary", headers=ana)).json()
    canary = next(n for z in resident["zones"] for n in z["nodes"] if n["node_id"] == "canary")
    assert (canary["last_command"]["status"], canary["last_command"]["requested_by_name"]) == ("accepted", None)


@pytest.mark.parametrize("user", ["mihai", "admin", "tehnician"])
async def test_scoped_staff_can_configure_detector_with_exact_wire_commands(client, mqtt, user):
    await handle_hardware_message("canary/status", json.dumps(air_doc(gas_detector={"enabled": False})).encode())
    for command in ("DETECTOR_ON", "DETECTOR_OFF"):
        response = await _send(client, "canary", command, user)
        assert response.status_code == 202, response.text
        assert mqtt.published[-1] == ("canary/gas-detector/set", command, 1, False)
        await dispatch("canary/command/result", json.dumps({"command": command, "accepted": True, "state": "enabled"}).encode())
        items = (await client.get("/api/v1/nodes/canary/commands", headers=await _hdr(client, user))).json()
        assert (items[0]["command"], items[0]["status"]) == (command, "accepted")
        await _age_commands(5)


@pytest.mark.parametrize("detector", [None, [], {}, {"alarm": False}, {"enabled": 0}, {"enabled": "false"}, {"enabled": None}])
async def test_detector_configuration_requires_explicit_boolean_capability(client, mqtt, detector):
    await handle_hardware_message("canary/status", json.dumps(air_doc(gas_detector=detector)).encode())
    response = await _send(client, "canary", "DETECTOR_OFF")
    assert response.status_code == 409, response.text
    assert "firmware" in response.json()["detail"].lower()
    assert mqtt.published == []
    assert (await _send(client, "canary", "TEST")).status_code == 202


async def test_detector_configuration_never_allowed_for_residents_and_stays_scoped(client, mqtt):
    await handle_hardware_message("canary/status", json.dumps(air_doc(gas_detector={"enabled": True})).encode())
    await handle_hardware_message("water-sensor/status", json.dumps(water_doc()).encode())
    await client.patch("/api/v1/nodes/canary", json={"zone_id": "zone_kitchen"}, headers=await _hdr(client, "mihai"))
    for command in ("DETECTOR_ON", "DETECTOR_OFF"):
        assert (await _send(client, "canary", command, "ana")).status_code == 403
        assert (await _send(client, "canary", command, "dispecer")).status_code == 403
        assert (await _send(client, "water-sensor", command)).status_code == 422
    async with SessionLocal() as s:
        s.add(Building(id="bld_other", name="Other"))
        s.add_all([User(id="usr_other_manager", username="other_manager", role="hoa_manager"),
                   User(id="usr_other_tech", username="other_tech", role="technician")])
        await s.flush()
        s.add_all([StaffBuilding(user_id="usr_other_manager", building_id="bld_other"),
                   StaffBuilding(user_id="usr_other_tech", building_id="bld_other")])
        await s.commit()
    for user in ("other_manager", "other_tech"):
        assert (await _send(client, "canary", "DETECTOR_OFF", user)).status_code == 404
    assert mqtt.published == []
