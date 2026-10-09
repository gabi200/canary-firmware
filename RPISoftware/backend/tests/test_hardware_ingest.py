"""Hardware MQTT ingestion end to end, through the real handler (no broker needed)."""

from __future__ import annotations

import hashlib
import json
import time
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select

from app.analytics import nodes as nodes_module
from app.db import SessionLocal
from app.ingestion import hardware
from app.ingestion.hardware import handle_hardware_message
from app.ingestion.mqtt import dispatch
from app.models import Device, Incident, Node, NodeStatus, Notification, OccupancyEstimate, SensorReading
from app.retention import prune_old_rows
from tests.conftest import auth_token, telemetry
from tests.hardware_docs import air_doc, water_doc

CLOSED_VALVE = {"requested": "closed", "applied": "closed", "relay_active": True}


@pytest.fixture(autouse=True)
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


@pytest.fixture
def ws_events(monkeypatch) -> list[dict]:
    events: list[dict] = []

    async def capture(building_id: str, message: dict) -> None:
        events.append(message)

    monkeypatch.setattr(nodes_module.manager, "broadcast", capture)
    return events


async def publish(base: str, doc, *, retain: bool = False, suffix: str = "status") -> None:
    raw = doc if isinstance(doc, bytes) else json.dumps(doc).encode()
    await handle_hardware_message(f"{base}/{suffix}", raw, retain=retain)


async def _node(node_id: str) -> Node | None:
    async with SessionLocal() as s:
        return await s.get(Node, node_id)


async def _count(model, *where) -> int:
    async with SessionLocal() as s:
        return await s.scalar(select(func.count()).select_from(model).where(*where))


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _active(client) -> list[dict]:
    r = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True},
                         headers=await _hdr(client, "mihai"))
    return r.json()


async def test_first_status_registers_node_devices_and_readings(client, ws_events):
    await publish("canary", air_doc())

    node = await _node("canary")
    assert (node.kind, node.mqtt_base, node.name, node.firmware) == ("air", "canary", "canary", "1.0.0")
    assert (node.building_id, node.zone_id, node.boot_epoch, node.last_uptime_ms) == ("bld_007", "zone_hallway", 1, 600000)
    assert node.online and node.last_seen_ts is not None and node.last_status["co"]["ppm"] == 3

    async with SessionLocal() as s:
        devices = (await s.scalars(select(Device).where(Device.id.like("canary:%")))).all()
        assert {d.id: d.sensor_type for d in devices} == {
            "canary:co": "co",
            "canary:gas": "combustible_gas",
            "canary:particulate": "particulate",
            "canary:presence": "radar_presence",
        }
        assert all((d.zone_id, d.unit_id, d.floor_id, d.status, d.fw_version) ==
                   ("zone_hallway", "common", "flr_03", "ok", "1.0.0") for d in devices)
        readings = (await s.scalars(select(SensorReading).where(SensorReading.device_id.like("canary:%")))).all()
        assert {r.device_id for r in readings} == {d.id for d in devices}
        assert all((r.epoch, r.seq, r.zone_id) == (1, 600000, "zone_hallway") for r in readings)
        occupancy = (await s.scalars(select(OccupancyEstimate))).all()
        assert [(o.zone_id, o.persons_est) for o in occupancy] == [("zone_hallway", 1.0)]
    assert await _count(NodeStatus) == 1
    assert await _active(client) == []

    event = next(e for e in ws_events if e["type"] == "node")
    assert set(event) == {"type", "building_id", "node_id", "kind", "zone_id", "online", "status", "ts"}
    assert (event["node_id"], event["kind"], event["online"], event["status"]) == ("canary", "air", True, "ok")
    assert event["ts"].endswith("Z")

    await publish("water-sensor", water_doc())
    water = await _node("water-sensor")
    assert (water.kind, water.boot_epoch, water.last_uptime_ms) == ("water", 1, 123456)
    async with SessionLocal() as s:
        leak = await s.get(Device, "water-sensor:leak")
        assert (leak.sensor_type, leak.zone_id) == ("water_leak", "zone_hallway")


async def test_co_danger_document_reaches_evacuation(client):
    await publish("canary", air_doc())
    await publish("canary", air_doc(uptime_ms=615000, co={"ppm": 180, "peak_ppm": 180, "state": "danger"},
                                    alarm={"state": "sounding", "hazard": "co", "sounding": True}))

    incidents = await _active(client)
    assert [(i["hazard_type"], i["state"], i["severity"]) for i in incidents] == [("co", "evacuation", "critical")]

    summary = (await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "ana"))).json()
    assert (summary["status"], summary["headline"], summary["active_incidents"]) == (
        "danger", "EVACUATE NOW — Carbon monoxide", 1,
    )
    node = summary["zones"][0]["nodes"][0]
    co = next(i for i in node["indicators"] if i["key"] == "co")
    assert (node["status"], co["value"], co["level"]) == ("danger", "Dangerous", "danger")


async def test_gas_is_graded_with_the_device_adc_thresholds(client):
    # 1200 ADC is "ok" for the device (warn 1500) but would be over the 1000 ppm default
    await publish("canary", air_doc(gas={"adc": 1200, "state": "ok"}))
    assert await _active(client) == []

    # the device's own danger grading drives the alarm even though 2300 < the 5000 ppm default
    await publish("canary", air_doc(uptime_ms=615000, gas={"adc": 2300, "peak_adc": 2300, "state": "danger"}))
    assert [(i["hazard_type"], i["state"]) for i in await _active(client)] == [("combustible_gas", "evacuation")]


async def test_particulate_danger_alarms_without_evacuating(client):
    await publish("canary", air_doc(particulate={"pm2_5": 180, "pm10": 210, "state": "danger"}))
    incidents = await _active(client)
    assert [(i["hazard_type"], i["state"]) for i in incidents] == [("particulate", "alarm")]
    async with SessionLocal() as s:
        titles = set((await s.scalars(select(Notification.title))).all())
    assert "Smoke / particulates ALARM" in titles


async def test_water_leak_alarms_then_dry_documents_clear_it(client):
    await publish("water-sensor", water_doc(uptime_ms=1000))
    await publish("water-sensor", water_doc(uptime_ms=2000, sensor={"state": "wet", "adc": 1500}, leak_latched=True,
                                            valve=CLOSED_VALVE, alarm={"state": "sounding", "sounding": True}))
    incidents = await _active(client)
    assert [(i["hazard_type"], i["state"]) for i in incidents] == [("water_leak", "alarm")]
    incident_id = incidents[0]["id"]

    async with SessionLocal() as s:
        bodies = (await s.scalars(select(Notification.body).where(Notification.incident_id == incident_id,
                                                                  Notification.state == "alarm"))).all()
    assert bodies and all("closed automatically" in b and "evacuate" not in b.lower() for b in bodies)

    for uptime in (3000, 4000, 5000):  # dry but still latched, valve closed
        await publish("water-sensor", water_doc(uptime_ms=uptime, leak_latched=True, valve=CLOSED_VALVE))
    assert await _active(client) == []
    inc = (await client.get(f"/api/v1/incidents/{incident_id}", headers=await _hdr(client, "mihai"))).json()
    assert inc["state"] == "resolution"

    # the latch and the closed valve are reported by the analysis instead
    summary = (await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "ana"))).json()
    node = summary["zones"][0]["nodes"][0]
    values = {i["key"]: i["value"] for i in node["indicators"]}
    assert values == {"leak": "Leak cleared — inspect", "valve": "Closed", "health": "Online"}
    assert (summary["status"], node["status"]) == ("attention", "attention")


async def test_retained_duplicate_is_ignored_and_retained_never_refreshes_liveness(client):
    doc = air_doc(uptime_ms=700000)
    await publish("canary", doc)
    first = await _node("canary")
    readings = await _count(SensorReading)

    await publish("canary", doc, retain=True)  # broker re-delivery after a hub reconnect
    assert await _count(NodeStatus) == 1
    assert await _count(SensorReading) == readings

    # a retained document the hub has not seen is stored, but the node is not "seen"
    await publish("canary", air_doc(uptime_ms=715000, co={"ppm": 4}), retain=True)
    node = await _node("canary")
    assert (node.last_uptime_ms, node.last_seen_ts) == (715000, first.last_seen_ts)
    assert await _count(NodeStatus) == 2
    async with SessionLocal() as s:
        device = await s.get(Device, "canary:co")
        assert device.last_seen_ts == first.last_seen_ts

    await publish("canary", air_doc(uptime_ms=730000))  # live
    assert (await _node("canary")).last_seen_ts > first.last_seen_ts


async def test_reboot_bumps_boot_epoch(client):
    await publish("canary", air_doc(uptime_ms=900000))
    await publish("canary", air_doc(uptime_ms=5000))
    assert (await _node("canary")).boot_epoch == 2
    async with SessionLocal() as s:
        keys = set((await s.execute(select(SensorReading.epoch, SensorReading.seq)
                                    .where(SensorReading.device_id == "canary:co"))).all())
    assert keys == {(1, 900000), (2, 5000)}


async def test_availability_offline_and_online(client, ws_events):
    await publish("canary", air_doc())
    await publish("canary", b"offline", suffix="availability")

    node = await _node("canary")
    assert not node.online
    async with SessionLocal() as s:
        statuses = set((await s.scalars(select(Device.status).where(Device.id.like("canary:%")))).all())
    assert statuses == {"offline"}
    assert ws_events[-1]["online"] is False and ws_events[-1]["status"] == "attention"

    summary = (await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "ana"))).json()
    node_view = summary["zones"][0]["nodes"][0]
    values = {i["key"]: i["value"] for i in node_view["indicators"]}
    assert (summary["nodes_online"], node_view["online"], node_view["status"]) == (0, False, "attention")
    assert (values["health"], values["co"]) == ("Offline", "No data")

    await publish("canary", b"garbage", suffix="availability")
    assert not (await _node("canary")).online
    await publish("canary", b"online", suffix="availability")
    assert (await _node("canary")).online


async def test_availability_before_registration_is_applied(client):
    await publish("water-sensor", b"offline", suffix="availability", retain=True)
    await publish("water-sensor", water_doc(), retain=True)
    node = await _node("water-sensor")
    assert node is not None and not node.online


async def test_summary_for_resident_is_analysis_only(client):
    await publish("canary", air_doc(
        co={"ppm": 41.3}, gas={"adc": 1357}, particulate={"pm1_0": 11.1, "pm2_5": 12.9, "pm10": 31.7},
        climate={"temperature_c": 21.6, "humidity_percent": 44.4},
        presence={"stationary_distance_cm": 187, "detection_distance_cm": 187}, wifi={"rssi": -67},
    ))
    await publish("water-sensor", water_doc(sensor={"adc": 312}))

    resp = await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "ana"))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert set(body) == {"building_id", "generated_ts", "status", "headline", "nodes_total", "nodes_online",
                         "active_incidents", "zones"}
    assert (body["status"], body["headline"], body["nodes_total"], body["nodes_online"]) == ("ok", "All clear", 2, 2)
    [zone] = body["zones"]
    # Who is home is manager/dispatcher-only (like /occupancy): hidden from residents.
    assert (zone["zone_id"], zone["zone_label"], zone["status"], zone["occupied"]) == ("zone_hallway", "Hol", "ok", None)
    assert all(i["key"] != "occupancy" for n in zone["nodes"] for i in n["indicators"])
    manager = (await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "mihai"))).json()
    assert manager["zones"][0]["occupied"] is True
    for node in zone["nodes"]:
        assert set(node) == {"node_id", "kind", "name", "zone_id", "online", "stale", "last_seen_ts", "status",
                             "headline", "advice", "indicators"}
        for indicator in node["indicators"]:
            assert set(indicator) == {"key", "label", "level", "value", "detail", "trend"}

    def strip_ts(obj):
        if isinstance(obj, dict):
            return {k: strip_ts(v) for k, v in obj.items() if not k.endswith("_ts")}
        if isinstance(obj, list):
            return [strip_ts(v) for v in obj]
        return obj

    text = json.dumps(strip_ts(body))
    for raw in ("41.3", "1357", "11.1", "12.9", "31.7", "21.6", "44.4", "187", "-67", "312", "600000", "123456"):
        assert raw not in text, raw
    assert body["generated_ts"].endswith("Z")

    assert (await client.get("/api/v1/buildings/nope/summary", headers=await _hdr(client, "ana"))).status_code == 404
    assert (await client.get("/api/v1/buildings/bld_007/summary")).status_code in (401, 403)


async def test_nodes_and_history_are_for_managers_and_dispatchers(client):
    await publish("canary", air_doc(uptime_ms=600000))
    await publish("canary", air_doc(uptime_ms=615000, co={"ppm": 4}, presence={"detected": False}))

    ana = await _hdr(client, "ana")
    assert (await client.get("/api/v1/buildings/bld_007/nodes", headers=ana)).status_code == 403
    assert (await client.get("/api/v1/nodes/canary/history", headers=ana)).status_code == 403

    mihai = await _hdr(client, "mihai")
    resp = await client.get("/api/v1/buildings/bld_007/nodes", headers=mihai)
    assert resp.status_code == 200, resp.text
    [node] = resp.json()
    assert (node["id"], node["mqtt_base"], node["kind"], node["boot_epoch"], node["zone_id"]) == (
        "canary", "canary", "air", 1, "zone_hallway",
    )
    assert node["status"]["co"]["ppm"] == 4  # raw document, verbatim
    assert (node["analysis"]["node_id"], node["analysis"]["status"]) == ("canary", "ok")
    assert node["last_seen_ts"].endswith("Z")

    resp = await client.get("/api/v1/nodes/canary/history", headers=mihai)
    assert resp.status_code == 200, resp.text
    history = resp.json()
    assert (history["node_id"], history["minutes"]) == ("canary", 60)
    assert history["fields"] == ["co.ppm", "gas.adc", "particulate.pm1_0", "particulate.pm2_5", "particulate.pm10",
                                 "climate.temperature_c", "climate.humidity_percent", "presence.detected"]
    assert [p["values"]["co.ppm"] for p in history["points"]] == [3, 4]
    assert [p["values"]["presence.detected"] for p in history["points"]] == [1, 0]

    resp = await client.get("/api/v1/nodes/canary/history",
                            params={"minutes": 10080, "fields": "co.ppm, alarm.state,leak_latched,co"},
                            headers=await _hdr(client, "dispecer"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["points"][-1]["values"] == {"co.ppm": 4, "alarm.state": "inactive", "leak_latched": None,
                                                   "co": None}

    for params, code in (({"fields": "co ppm"}, 400), ({"minutes": 0}, 422), ({"minutes": 10081}, 422)):
        assert (await client.get("/api/v1/nodes/canary/history", params=params, headers=mihai)).status_code == code
    assert (await client.get("/api/v1/nodes/nope/history", headers=mihai)).status_code == 404


async def test_history_is_thinned_to_360_points(client):
    await publish("canary", air_doc(uptime_ms=1))
    async with SessionLocal() as s:
        now = datetime.now(timezone.utc)
        for i in range(1000):
            s.add(NodeStatus(node_id="canary", ts=now - timedelta(seconds=1000 - i), uptime_ms=i,
                             payload={"co": {"ppm": i}}))
        await s.commit()
    resp = await client.get("/api/v1/nodes/canary/history", params={"fields": "co.ppm"},
                            headers=await _hdr(client, "mihai"))
    points = resp.json()["points"]
    assert len(points) == 360
    assert points[0]["values"]["co.ppm"] == 0 and points[-1]["values"]["co.ppm"] == 3  # oldest .. newest
    assert [p["ts"] for p in points] == sorted(p["ts"] for p in points)


async def test_patch_moves_node_and_its_devices(client, ws_events):
    await publish("canary", air_doc())
    mihai = await _hdr(client, "mihai")

    resp = await client.patch("/api/v1/nodes/canary", json={"zone_id": "zone_kitchen", "name": "Kitchen air"},
                              headers=mihai)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert (body["zone_id"], body["name"], body["analysis"]["zone_id"]) == ("zone_kitchen", "Kitchen air", "zone_kitchen")
    assert ws_events[-1]["zone_id"] == "zone_kitchen"
    async with SessionLocal() as s:
        devices = (await s.scalars(select(Device).where(Device.id.like("canary:%")))).all()
    assert {(d.zone_id, d.unit_id) for d in devices} == {("zone_kitchen", "unit_0312")}

    # later readings land in the new zone
    await publish("canary", air_doc(uptime_ms=615000))
    async with SessionLocal() as s:
        zone = await s.scalar(select(SensorReading.zone_id).where(SensorReading.device_id == "canary:co")
                              .order_by(SensorReading.id.desc()).limit(1))
    assert zone == "zone_kitchen"
    summary = (await client.get("/api/v1/buildings/bld_007/summary", headers=mihai)).json()
    assert [(z["zone_id"], z["zone_label"]) for z in summary["zones"]] == [("zone_kitchen", "Bucatarie")]

    assert (await client.patch("/api/v1/nodes/canary", json={"zone_id": "nope"}, headers=mihai)).status_code == 400
    assert (await client.patch("/api/v1/nodes/nope", json={"name": "x"}, headers=mihai)).status_code == 404
    assert (await client.patch("/api/v1/nodes/canary", json={"name": "   "}, headers=mihai)).status_code == 422
    for user in ("ana", "dispecer"):
        r = await client.patch("/api/v1/nodes/canary", json={"name": "x"}, headers=await _hdr(client, user))
        assert r.status_code == 403
    r = await client.patch("/api/v1/nodes/canary", json={"name": "Admin name"}, headers=await _hdr(client, "admin"))
    assert (r.status_code, r.json()["name"], r.json()["zone_id"]) == (200, "Admin name", "zone_kitchen")


async def test_kind_mismatch_and_slug_clash(client):
    await publish("canary", air_doc())
    await publish("canary", water_doc())  # misconfigured second device on the same base
    assert (await _node("canary")).kind == "air"
    assert await _count(NodeStatus) == 1

    await publish("Canary", water_doc())  # different base, same slug
    clash_id = "canary-" + hashlib.sha1(b"Canary").hexdigest()[:6]
    node = await _node(clash_id)
    assert (node.mqtt_base, node.kind) == ("Canary", "water")


async def test_presence_readings_only_on_change_or_every_5_minutes(client):
    for uptime in (1000, 2000, 3000):
        await publish("canary", air_doc(uptime_ms=uptime))
    assert await _count(SensorReading, SensorReading.device_id == "canary:presence") == 1

    await publish("canary", air_doc(uptime_ms=4000, presence={"detected": False}))
    assert await _count(SensorReading, SensorReading.device_id == "canary:presence") == 2

    hardware._last_presence["canary"] = (0.0, time.monotonic() - 301)
    await publish("canary", air_doc(uptime_ms=5000, presence={"detected": False}))
    assert await _count(SensorReading, SensorReading.device_id == "canary:presence") == 3


async def test_hostile_messages_are_dropped_without_raising(client):
    bad = [
        ("canary/status", b"online"),
        ("canary/status", b"{not json"),
        ("canary/status", b'{"co": {}, "gas": {}, "particulate": {}}'),  # no uptime
        ("canary/status", json.dumps(air_doc(uptime_ms=True)).encode()),
        ("canary/status", b"x" * 100_000),
        ("canary/status", b'{"uptime_ms": 5, "co": {}, "gas": {}, "particulate": {"x": [[[[1]]]]}}'),
        ("/status", json.dumps(air_doc()).encode()),
        ("a" * 300 + "/status", json.dumps(air_doc()).encode()),
        ("canary/availability", b"\xff" * 10),
        ("canary/command/result", b'{"command":"TEST","accepted":true,"state":"self_test"}'),
    ]
    for topic, raw in bad:
        await handle_hardware_message(topic, raw)
        await dispatch(topic, raw)
    assert await _count(Node) == 0

    # odd field types register the node but never raise; bad channels are just skipped
    await publish("canary", air_doc(co={"state": ["ok"]}, gas={"adc": "640"}, particulate={"pm2_5": None},
                                    climate={"temperature_c": "hot"}, wifi=None, device={"name": 7}))
    node = await _node("canary")
    assert node is not None and node.name == "canary"
    assert await _count(SensorReading, SensorReading.device_id.like("canary:%")) == 1  # presence only
    resp = await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "ana"))
    assert resp.status_code == 200


async def test_legacy_topics_still_route_through_dispatch(client):
    legacy = telemetry("dev_gas_kitchen", "combustible_gas", 120, zone_id="zone_kitchen", unit_id="unit_0312")
    await dispatch("canary/v1/bld_007/flr_03/unit_0312/zone_kitchen/dev_gas_kitchen/telemetry",
                   json.dumps(legacy).encode())
    assert await _count(SensorReading, SensorReading.device_id == "dev_gas_kitchen") == 1

    # outside the legacy prefix a `telemetry` topic is not ingested
    await dispatch("other/app/telemetry", json.dumps({**legacy, "seq": 2}).encode())
    assert await _count(SensorReading, SensorReading.device_id == "dev_gas_kitchen") == 1


async def test_retention_prunes_only_old_time_series(client):
    await publish("canary", air_doc())
    old = datetime.now(timezone.utc) - timedelta(days=15)
    async with SessionLocal() as s:
        s.add(NodeStatus(node_id="canary", ts=old, uptime_ms=1, payload={}))
        s.add(SensorReading(device_id="canary:co", building_id="bld_007", floor_id="flr_03", unit_id="common",
                            zone_id="zone_hallway", sensor_type="co", value=1, epoch=0, seq=1, ts=old))
        s.add(OccupancyEstimate(building_id="bld_007", zone_id="zone_hallway", persons_est=3, ts=old))
        await s.commit()

    deleted = await prune_old_rows()
    assert deleted == {"node_status": 1, "sensor_readings": 1, "occupancy_estimates": 1, "signature_assessments": 0}
    assert await _count(NodeStatus) == 1
    assert await _count(SensorReading, SensorReading.device_id == "canary:co") == 1


async def test_latest_occupancy_per_zone(client):
    from app.occupancy.service import OccupancyService

    now = datetime.now(timezone.utc)
    async with SessionLocal() as s:
        for minutes, zone, persons in ((30, "zone_hallway", 4), (10, "zone_hallway", 2), (20, "zone_bedroom", 1),
                                       (5, "zone_bedroom", 0)):
            s.add(OccupancyEstimate(building_id="bld_007", zone_id=zone, persons_est=persons,
                                    ts=now - timedelta(minutes=minutes)))
        s.add(OccupancyEstimate(building_id="other", zone_id="zone_hallway", persons_est=9, ts=now))
        await s.commit()
        assert await OccupancyService(s).latest_per_zone("bld_007") == {"zone_hallway": 2, "zone_bedroom": 0}


async def test_incident_rows_untouched_by_hardware_analysis(client):
    """The summary reads incidents; it must never modify them."""
    await publish("canary", air_doc(co={"ppm": 180, "state": "danger"}))
    async with SessionLocal() as s:
        before = [(i.id, i.state, i.updated_ts) for i in (await s.scalars(select(Incident))).all()]
    await client.get("/api/v1/buildings/bld_007/summary", headers=await _hdr(client, "ana"))
    async with SessionLocal() as s:
        after = [(i.id, i.state, i.updated_ts) for i in (await s.scalars(select(Incident))).all()]
    assert before == after and before


async def test_retention_deletes_in_bounded_batches(client, monkeypatch):
    from app import retention

    monkeypatch.setattr(retention, "PRUNE_BATCH", 2)
    await publish("canary", air_doc())
    old = datetime.now(timezone.utc) - timedelta(days=15)
    async with SessionLocal() as s:
        for i in range(5):
            s.add(NodeStatus(node_id="canary", ts=old, uptime_ms=i, payload={}))
        await s.commit()

    assert (await prune_old_rows())["node_status"] == 5
    assert await _count(NodeStatus) == 1  # the fresh snapshot survives


async def test_broadcast_is_time_boxed_and_drops_only_broken_sockets(monkeypatch):
    import asyncio

    from app.realtime import ws as ws_module

    monkeypatch.setattr(ws_module, "SEND_TIMEOUT_S", 0.05)

    class Sock:
        def __init__(self, behaviour: str) -> None:
            self.behaviour, self.got = behaviour, []

        async def send_json(self, message: dict) -> None:
            if self.behaviour == "stalled":
                await asyncio.sleep(10)
            if self.behaviour == "broken":
                raise RuntimeError("closed")
            self.got.append(message)

    mgr = ws_module.ConnectionManager()
    ok, stalled, broken = Sock("ok"), Sock("stalled"), Sock("broken")
    mgr._rooms["b"] = {ok, stalled, broken}
    started = asyncio.get_running_loop().time()
    await mgr.broadcast("b", {"type": "node"})
    assert asyncio.get_running_loop().time() - started < 1
    assert ok.got == [{"type": "node"}]
    assert mgr._rooms["b"] == {ok, stalled}  # a slow client misses a frame; a broken one is dropped


def test_websocket_tokens_are_redacted_from_server_logs():
    import logging

    from app.main import RedactTokens

    record = logging.LogRecord("uvicorn.error", logging.INFO, __file__, 1, '%s - "WebSocket %s" [accepted]',
                               ("1.2.3.4:5", "/api/v1/ws/incidents?building_id=bld_007&token=eyJ.abc.def"), None)
    RedactTokens().filter(record)
    assert record.getMessage() == '1.2.3.4:5 - "WebSocket /api/v1/ws/incidents?building_id=bld_007&token=***" [accepted]'
