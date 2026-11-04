"""Demo incidents sound the real nodes, once per incident, without touching the incident path."""

from __future__ import annotations

import logging

import pytest
from sqlalchemy import func, select

from app import commands, demo_bridge
from app.db import SessionLocal
from app.enums import ALARMED_STATES, IncidentState
from app.ingestion import broker
from app.mode import set_mode
from app.models import AuditLogEntry, DeviceCommand, Incident, Node, Notification, ResidentUnit
from tests.conftest import auth_token, telemetry

AIR = ("real-air/buzzer/set", "TEST", 1, False)
WATER = ("real-water/valve/set", "CLOSE", 1, False)


class FakeMqtt:
    def __init__(self) -> None:
        self.published: list[tuple[str, str, int, bool]] = []
        self.on_publish = None

    async def publish(self, topic: str, payload: str, *, qos: int = 0, retain: bool = False) -> None:
        if self.on_publish is not None:
            await self.on_publish(topic)
        self.published.append((topic, payload, qos, retain))


@pytest.fixture(autouse=True)
def mqtt(monkeypatch):
    fake = FakeMqtt()
    monkeypatch.setattr(broker, "client", fake)
    return fake


@pytest.fixture
def no_rate_limit(monkeypatch):
    """too_soon would hide a double fire within 3 s; these tests see every attempt."""

    async def never(session, node_id):
        return False

    monkeypatch.setattr(commands, "too_soon", never)


async def _real_nodes(*, air_online: bool = True, water_online: bool = True) -> None:
    async with SessionLocal() as s:
        for node_id, kind, online in (("real-air", "air", air_online), ("real-water", "water", water_online)):
            s.add(Node(id=node_id, kind=kind, mqtt_base=node_id, name=node_id, firmware="t",
                       building_id="bld_live", zone_id="zone_live", online=online, boot_epoch=1))
        await s.commit()


async def _gas_leak(client, *, seq: int = 1, value: float = 6000) -> dict:
    """The "Simulate gas leak" telemetry of the demo building."""
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", value, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=seq, edge_state="alarm"))
    assert resp.status_code == 200, resp.text
    await demo_bridge.drain()
    return resp.json()


async def _hdr(client, username: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, username)}"}


async def _command_rows() -> int:
    async with SessionLocal() as s:
        return await s.scalar(select(func.count()).select_from(DeviceCommand))


async def test_demo_gas_leak_beeps_real_nodes(client, mqtt):
    await _real_nodes()
    body = await _gas_leak(client)
    assert body["incident_state"] == "evacuation"
    assert sorted(mqtt.published) == sorted([AIR, WATER])
    async with SessionLocal() as s:
        rows = (await s.scalars(select(DeviceCommand))).all()
        assert {r.requested_by_user_id for r in rows} == {"system:demo"}
        assert {(r.node_id, r.building_id, r.command) for r in rows} == {
            ("real-air", "bld_live", "TEST"), ("real-water", "bld_live", "CLOSE")}
        actors = await s.scalars(select(AuditLogEntry.actor).where(AuditLogEntry.action == "device_command"))
        assert set(actors.all()) == {"system:demo"}


async def test_demo_mirror_once_per_incident(client, mqtt, no_rate_limit):
    """Critical reading: detection -> alarm -> escalation -> evacuation fires one mirror; so do
    the readings and manual actions that follow."""
    await _real_nodes()
    body = await _gas_leak(client, seq=1)
    assert sorted(mqtt.published) == sorted([AIR, WATER])
    await _gas_leak(client, seq=2)
    resp = await client.post(f"/api/v1/incidents/{body['incident_id']}/order-evacuation",
                             headers=await _hdr(client, "mihai"))
    assert resp.status_code == 200, resp.text
    await demo_bridge.drain()
    assert len(mqtt.published) == 2


async def test_demo_mirror_silent_moving_between_alarmed_states(client, mqtt, no_rate_limit):
    """A corroborated alarm fires; the later alarm -> evacuation by a manager does not."""
    await _real_nodes()
    for seq, (device, zone) in enumerate((("dev_gas_a", "zone_kitchen"), ("dev_gas_b", "zone_hallway")), 1):
        resp = await client.post("/api/v1/telemetry", json=telemetry(
            device, "combustible_gas", 1500, zone_id=zone, unit_id="unit_0312", seq=seq))
        assert resp.status_code == 200, resp.text
    await demo_bridge.drain()
    body = resp.json()
    assert body["incident_state"] in ("alarm", "escalation")
    assert len(mqtt.published) == 2

    resp = await client.post(f"/api/v1/incidents/{body['incident_id']}/order-evacuation",
                             headers=await _hdr(client, "mihai"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["state"] == "evacuation"
    await demo_bridge.drain()
    assert len(mqtt.published) == 2


async def test_demo_incident_below_alarm_stays_silent(client, mqtt):
    await _real_nodes()
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 1500, zone_id="zone_kitchen", unit_id="unit_0312", seq=1))
    assert resp.json()["incident_state"] in ("detection", "verification")
    await demo_bridge.drain()
    assert mqtt.published == []


async def test_new_incident_after_resolve_mirrors_again(client, mqtt, no_rate_limit):
    """A closed incident is never reopened: the next leak is a new incident with its own mirror."""
    await _real_nodes()
    first = await _gas_leak(client, seq=1)
    resp = await client.post(f"/api/v1/incidents/{first['incident_id']}/resolve",
                             headers=await _hdr(client, "mihai"))
    assert resp.status_code == 200, resp.text
    await demo_bridge.drain()
    assert len(mqtt.published) == 2  # resolving mirrors nothing

    second = await _gas_leak(client, seq=2)
    assert second["incident_id"] != first["incident_id"]
    assert len(mqtt.published) == 4


@pytest.mark.parametrize("from_state", list(IncidentState))
@pytest.mark.parametrize("to_state", list(IncidentState))
def test_should_mirror_only_on_first_entry_into_alarmed(from_state, to_state):
    demo = Incident(building_id="bld_007")
    expected = to_state in ALARMED_STATES and from_state not in ALARMED_STATES
    assert demo_bridge.should_mirror(demo, from_state, to_state) is expected
    assert demo_bridge.should_mirror(Incident(building_id="bld_live"), from_state, to_state) is False


async def test_real_incident_unaffected_by_demo_mode(client, mqtt):
    await _real_nodes()
    async with SessionLocal() as s:
        await set_mode(s, "demo", "usr_mihai")
    doc = telemetry("real-air:combustible_gas", "combustible_gas", 6000, zone_id="zone_live", unit_id="unit_live",
                    seq=1, edge_state="alarm")
    doc["location"].update(building_id="bld_live", floor_id="flr_live")
    resp = await client.post("/api/v1/telemetry", json=doc)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["incident_state"] == "evacuation"
    await demo_bridge.drain()
    assert mqtt.published == []
    assert await _command_rows() == 0
    async with SessionLocal() as s:
        residents = set((await s.scalars(
            select(ResidentUnit.user_id).where(ResidentUnit.building_id == "bld_live"))).all())
        notified = set((await s.scalars(
            select(Notification.recipient_user_id).where(Notification.incident_id == body["incident_id"]))).all())
    assert residents and residents <= notified


async def test_offline_real_node_skipped(client, mqtt):
    await _real_nodes(air_online=False)
    body = await _gas_leak(client)
    assert body["incident_state"] == "evacuation"
    assert mqtt.published == [WATER]
    assert await _command_rows() == 1


async def test_node_commanded_a_moment_ago_is_skipped(client, mqtt):
    await _real_nodes()
    resp = await client.post("/api/v1/nodes/real-air/commands", json={"command": "SILENCE"},
                             headers=await _hdr(client, "mihai"))
    assert resp.status_code == 202, resp.text
    mqtt.published.clear()
    await _gas_leak(client)
    assert mqtt.published == [WATER]


async def test_commands_go_out_after_the_incident_committed(client, mqtt):
    """When the first publish happens, another connection already reads the finished incident."""
    await _real_nodes()
    seen: list[str] = []

    async def check(topic: str) -> None:
        async with SessionLocal() as s:
            seen.extend((await s.scalars(select(Incident.state))).all())

    mqtt.on_publish = check
    await _gas_leak(client)
    assert seen and set(seen) == {"evacuation"}


async def test_rolled_back_transition_sends_nothing(client, mqtt):
    await _real_nodes()
    async with SessionLocal() as s:
        incident = Incident(building_id="bld_007", hazard_type="combustible_gas", primary_zone_id="zone_kitchen",
                            state="detection", severity="critical", distinct_device_ids=[], affected_zone_ids=[])
        s.add(incident)
        await s.flush()
        demo_bridge.queue(s, incident, IncidentState.detection, IncidentState.alarm)
        await s.rollback()
    await demo_bridge.drain()
    assert mqtt.published == []


async def test_savepoint_commit_does_not_fire_the_mirror(client, mqtt):
    """SQLAlchemy runs after_commit on a savepoint release too; only the real commit may fire."""
    await _real_nodes()
    async with SessionLocal() as s:
        incident = Incident(building_id="bld_007", hazard_type="combustible_gas", primary_zone_id="zone_kitchen",
                            state="detection", severity="critical", distinct_device_ids=[], affected_zone_ids=[])
        s.add(incident)
        await s.flush()
        demo_bridge.queue(s, incident, IncidentState.detection, IncidentState.alarm)
        async with s.begin_nested():
            pass
        await demo_bridge.drain()
        assert mqtt.published == []
        with pytest.raises(RuntimeError):  # a rolled back savepoint must not lose the mirror either
            async with s.begin_nested():
                raise RuntimeError("inner work failed")
        incident.state = "alarm"
        await s.commit()
    await demo_bridge.drain()
    assert sorted(mqtt.published) == sorted([AIR, WATER])


async def test_broker_down_never_reaches_the_incident(client, monkeypatch, caplog):
    await _real_nodes()
    monkeypatch.setattr(broker, "client", None)
    with caplog.at_level(logging.ERROR, logger="canary.demo_bridge"):
        body = await _gas_leak(client)
    assert body["incident_state"] == "evacuation"
    assert await _command_rows() == 0
    assert "real-air" in caplog.text and "real-water" in caplog.text
    async with SessionLocal() as s:
        assert (await s.get(Incident, body["incident_id"])).state == "evacuation"


async def test_failure_on_one_node_still_commands_the_next(client, mqtt, monkeypatch):
    await _real_nodes()
    real_send = commands.send
    calls: list[str] = []

    async def flaky(session, node, command, user_id):
        calls.append(node.id)
        if len(calls) == 1:
            session.add(AuditLogEntry(actor="x", action="half_done", target=node.id))
            await session.flush()
            raise RuntimeError("database hiccup")
        return await real_send(session, node, command, user_id)

    monkeypatch.setattr(commands, "send", flaky)
    await _gas_leak(client)
    assert len(calls) == 2 and len(mqtt.published) == 1
    async with SessionLocal() as s:  # the failed node's half-done work is gone
        assert await s.scalar(select(func.count()).select_from(AuditLogEntry)
                              .where(AuditLogEntry.action == "half_done")) == 0


async def test_failing_decision_never_breaks_the_incident(client, mqtt, monkeypatch):
    def boom(*args):
        raise RuntimeError("bridge bug")

    monkeypatch.setattr(demo_bridge, "should_mirror", boom)
    await _real_nodes()
    body = await _gas_leak(client)
    assert body["incident_state"] == "evacuation"
    assert mqtt.published == []


async def test_mirror_itself_never_raises(client, mqtt, monkeypatch):
    async def boom(*args, **kwargs):
        raise RuntimeError("database down")

    monkeypatch.setattr(demo_bridge, "_online_live_node_ids", boom)
    async with SessionLocal() as s:
        sent = await demo_bridge.mirror(s, Incident(building_id="bld_007"), IncidentState.detection,
                                        IncidentState.alarm)
    assert sent == []


async def test_system_actor_is_readable_in_the_apis(client):
    """`system:demo` has no user row: command lists show no requester name instead of failing."""
    await _real_nodes()
    await _gas_leak(client)
    hdr = await _hdr(client, "mihai")
    listed = await client.get("/api/v1/nodes/real-air/commands", headers=hdr)
    assert listed.status_code == 200, listed.text
    assert [(c["command"], c["requested_by_name"]) for c in listed.json()] == [("TEST", None)]
    nodes = await client.get("/api/v1/buildings/bld_live/nodes", headers=hdr)
    assert nodes.status_code == 200, nodes.text
    assert {n["id"]: n["last_command"]["requested_by_name"] for n in nodes.json()} == {
        "real-air": None, "real-water": None}
