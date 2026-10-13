"""Three-Pi mode (app.cluster): lease hand-over, failover, self-fencing, retained MQTT documents,
the node-to-node endpoints and the status view. One SQLite database stands in for the shared
Postgres, and the test drives the "database clock" so time can jump."""

from __future__ import annotations

import asyncio
import json
import sys
import types
from datetime import datetime, timedelta, timezone

import pytest

from app import cluster
from app.config import settings
from app.db import SessionLocal
from app.ingestion import hardware
from app.ingestion.hardware import handle_hardware_message
from app.models import ClusterLease, ClusterNode, Node
from app.realtime.ws import manager
from tests.conftest import auth_token
from tests.hardware_docs import air_doc

T0 = datetime(2026, 10, 13, 10, 0, tzinfo=timezone.utc)
SECRET = "s3cret"


@pytest.fixture
def triple(monkeypatch) -> dict:
    """Three-Pi settings (this process plays the `processing` Pi) and a test-driven DB clock."""
    for key, value in {
        "cluster_mode": "triple", "node_name": "processing", "processing_ip": "10.0.0.11", "web_ip": "10.0.0.12",
        "ai_ip": "10.0.0.13", "vip": "10.0.0.10", "cluster_secret": SECRET,
    }.items():
        monkeypatch.setattr(settings, key, value)
    clock = {"now": T0}

    async def db_now(_session) -> datetime:
        return clock["now"]

    monkeypatch.setattr(cluster, "db_now", db_now)
    monkeypatch.setattr(cluster, "_alive", {})
    monkeypatch.setattr(cluster, "_silent", set())
    monkeypatch.setattr(cluster, "_holds_processing", False)
    hardware.reset_state()
    yield clock
    hardware.reset_state()


async def beat(name: str, take: bool = True) -> tuple[bool, bool, bool]:
    """One heartbeat + lease round as Pi `name`: (wants processing, holds it, the lease was its own)."""
    settings.node_name = name
    return await cluster._round(take)


def at(clock: dict, seconds: float) -> None:
    clock["now"] = T0 + timedelta(seconds=seconds)


def test_desired_holder_prefers_the_home_node_once_it_settled():
    order, up = cluster.PROCESSING_ORDER, {"processing": T0, "web": T0 - timedelta(hours=1), "ai": T0}
    assert cluster.desired_holder(order, up, None, T0) == "processing"
    # web took over while processing was down; processing is back but keeps out for FAILBACK_S
    assert cluster.desired_holder(order, up, "web", T0 + timedelta(seconds=10)) == "web"
    assert cluster.desired_holder(order, up, "web", T0 + timedelta(seconds=30)) == "processing"
    # a dead holder is replaced at once by the best alive node
    assert cluster.desired_holder(order, {"web": T0, "ai": T0}, "processing", T0) == "web"
    assert cluster.desired_holder(order, {}, None, T0) is None


async def test_processing_fails_over_and_comes_back_home(client, triple):
    clock = triple
    assert await beat("processing") == (True, True, False)  # cold start: the home Pi takes it
    assert await beat("web") == (False, False, False)
    assert await beat("ai") == (False, False, False)

    # the processing Pi dies: nobody may take over while its lease can still be valid
    at(clock, 12)  # seen dead (NODE_TTL_S): web wants it, but the lease runs until LEASE_TTL_S
    assert await beat("web") == (True, False, False)
    at(clock, 16)
    assert await beat("web") == (True, True, False)

    # it comes back: web keeps processing until the home Pi has been up FAILBACK_S
    for t in (24, 33, 42, 51):
        at(clock, t)
        assert (await beat("processing"))[1] is False
        assert await beat("web") == (True, True, True)
    at(clock, 55)
    assert await beat("web") == (False, False, True)  # hand over: the loop halts, then releases
    await cluster._release()
    assert await beat("processing") == (True, True, False)
    async with SessionLocal() as s:
        lease = await s.get(ClusterLease, cluster.PROCESSING)
        assert (lease.holder, lease.acquired_ts) == ("processing", T0 + timedelta(seconds=55))


async def test_a_second_pi_with_the_same_name_is_kept_out(client, triple, monkeypatch):
    assert (await beat("processing"))[1] is True
    monkeypatch.setattr(cluster, "_INSTANCE", "another-process")  # e.g. a copied .env on the web Pi
    with pytest.raises(RuntimeError, match="already running"):
        await beat("processing")
    at(triple, 11)  # the first one went silent: the name is free again
    assert (await beat("processing"))[1] is True

    monkeypatch.setattr(cluster, "_INSTANCE", "a-restart")  # a graceful restart frees it at once
    await cluster._retire()
    assert (await beat("processing"))[1] is True


async def test_a_new_node_renews_but_never_takes_before_it_settled(client, triple):
    assert await beat("web", take=False) == (True, False, False)  # alone and not home: waits
    assert await beat("web", take=True) == (True, True, False)


async def test_run_starts_halts_and_fences_itself_when_the_database_is_gone(monkeypatch, triple):
    events: list[str] = []
    stop = asyncio.Event()
    rounds = iter([(True, True, False), RuntimeError("db down"), (True, True, True), (False, False, True)])

    async def scripted_round(take: bool) -> tuple[bool, bool, bool]:
        step = next(rounds, None)
        if step is None:
            stop.set()
            return False, False, False
        if isinstance(step, Exception):
            await asyncio.sleep(0.1)  # the database does not answer for longer than the deadline
            raise step
        return step

    def record(name: str):
        async def step() -> None:
            events.append(name)
        return step

    monkeypatch.setattr(cluster, "_round", scripted_round)
    monkeypatch.setattr(cluster, "_release", record("release"))
    monkeypatch.setattr(cluster, "_retire", record("retire"))
    monkeypatch.setattr(cluster, "TICK_S", 0.01)
    monkeypatch.setattr(cluster, "RENEW_DEADLINE_S", 0.05)
    await asyncio.wait_for(cluster.run(stop, record("start"), record("halt")), timeout=5)
    # took it; the DB vanished -> stopped; took it again; handed it over -> stopped, then released
    assert events == ["start", "halt", "start", "halt", "release", "retire"]


async def test_a_hung_database_round_cannot_delay_the_self_fence(monkeypatch, triple):
    events: list[str] = []
    calls = 0

    async def hung_round(take: bool) -> tuple[bool, bool, bool]:
        nonlocal calls
        calls += 1
        if calls == 1:
            return True, True, False
        await asyncio.Event().wait()  # a query to a primary that lost power: no answer, no reset
        raise AssertionError("unreachable")

    def record(name: str):
        async def step() -> None:
            events.append(name)
        return step

    monkeypatch.setattr(cluster, "_round", hung_round)
    monkeypatch.setattr(cluster, "_release", record("release"))
    monkeypatch.setattr(cluster, "_retire", record("retire"))
    monkeypatch.setattr(cluster, "TICK_S", 0.01)
    monkeypatch.setattr(cluster, "RENEW_DEADLINE_S", 0.05)
    stop = asyncio.Event()
    loop = asyncio.create_task(cluster.run(stop, record("start"), record("halt")))
    await asyncio.sleep(0.3)
    stop.set()
    await asyncio.wait_for(loop, timeout=2)
    assert events == ["start", "halt", "retire"]


async def test_a_verdict_older_than_the_deadline_does_not_start_processing(monkeypatch, triple):
    events: list[str] = []
    calls = 0

    async def slow_round(take: bool) -> tuple[bool, bool, bool]:
        nonlocal calls
        calls += 1
        if calls == 1:
            await asyncio.sleep(0.15)  # commits stalled past the deadline, then "held" after all
        return True, True, True

    def record(name: str):
        async def step() -> None:
            events.append(name)
        return step

    monkeypatch.setattr(cluster, "_round", slow_round)
    monkeypatch.setattr(cluster, "_retire", record("retire"))
    monkeypatch.setattr(cluster, "_release", record("release"))
    monkeypatch.setattr(cluster, "TICK_S", 0.01)
    monkeypatch.setattr(cluster, "RENEW_DEADLINE_S", 0.1)
    stop = asyncio.Event()
    loop = asyncio.create_task(cluster.run(stop, record("start"), record("halt")))
    await asyncio.sleep(0.12)
    assert events == []  # the slow round is still out: nothing started on its say-so
    await asyncio.sleep(0.15)
    stop.set()
    await asyncio.wait_for(loop, timeout=2)
    # the stale verdict was dropped; the next, fresh round started processing
    assert events[0] == "start" and calls >= 2


async def test_after_a_database_outage_only_the_home_node_takes_a_free_lease_at_once(monkeypatch, triple):
    """A Postgres failover silences every node's heartbeat; whichever node's round succeeds first
    afterwards must not grab processing from the home node (and hand it back 30 s later)."""
    takes: list[tuple[str, bool]] = []
    phase = {"now": "up"}
    stop = asyncio.Event()

    async def scripted_round(take: bool) -> tuple[bool, bool, bool]:
        takes.append((phase["now"], take))
        if phase["now"] == "outage":
            raise RuntimeError("database failing over")
        return False, False, False

    async def noop() -> None:
        return None

    monkeypatch.setattr(cluster, "_round", scripted_round)
    monkeypatch.setattr(cluster, "_retire", noop)
    monkeypatch.setattr(cluster, "TICK_S", 0.01)
    monkeypatch.setattr(cluster, "NODE_TTL_S", 0.2)
    settings.node_name = "web"  # not the processing Pi's home
    loop = asyncio.create_task(cluster.run(stop, noop, noop))
    await asyncio.sleep(0.4)  # past the cold-start settle: web may take a free lease now
    phase["now"] = "outage"
    await asyncio.sleep(0.4)  # longer than NODE_TTL_S
    phase["now"] = "back"
    await asyncio.sleep(0.1)  # within the new settle window
    phase["now"] = "settled"
    await asyncio.sleep(0.4)
    stop.set()
    await asyncio.wait_for(loop, timeout=2)

    def seen(name: str) -> set[bool]:
        return {take for p, take in takes if p == name}

    assert True in seen("up")
    assert seen("back") == {False}  # neither the first round after the outage nor the settle window
    assert True in seen("settled")


async def _publish(base: str, doc, *, retain: bool = False, suffix: str = "status") -> None:
    raw = doc if isinstance(doc, bytes) else json.dumps(doc).encode()
    await handle_hardware_message(f"{base}/{suffix}", raw, retain=retain)


async def _node(node_id: str) -> Node:
    async with SessionLocal() as s:
        return await s.get(Node, node_id)


async def test_retained_documents_from_another_pis_broker_are_not_trusted(client, triple):
    await _publish("canary", air_doc(uptime_ms=900000))
    await _publish("canary", air_doc(uptime_ms=5000), retain=True)  # an old copy, not a reboot
    node = await _node("canary")
    assert (node.boot_epoch, node.last_uptime_ms) == (1, 900000)

    await _publish("canary", b"offline", suffix="availability")
    await _publish("canary", b"online", suffix="availability", retain=True)  # may be stale: ignored
    assert not (await _node("canary")).online
    await _publish("canary", air_doc(uptime_ms=915000))  # live: proves the node is up
    assert (await _node("canary")).online
    await _publish("canary", b"offline", suffix="availability", retain=True)  # a last will still counts
    assert not (await _node("canary")).online


async def test_internal_endpoints_need_the_cluster_key(client, triple, monkeypatch):
    sent: list[tuple[str, dict]] = []

    async def capture(building_id: str, message: dict) -> None:
        sent.append((building_id, message))

    async def run_local(task: str, payload: dict) -> dict:
        if task != "echo":
            raise KeyError(task)
        return {"echo": payload}

    monkeypatch.setattr(manager, "send_local", capture)
    monkeypatch.setitem(sys.modules, "app.ai.offload", types.SimpleNamespace(run_local=run_local))
    body = {"building_id": "bld_007", "message": {"type": "incident", "state": "alarm"}}
    key = {cluster.KEY_HEADER: SECRET}

    assert (await client.post("/internal/cluster/broadcast", json=body)).status_code == 404
    assert (await client.post("/internal/cluster/broadcast", json=body,
                              headers={cluster.KEY_HEADER: "wrong"})).status_code == 404
    assert (await client.post("/internal/cluster/broadcast", json=body, headers=key)).status_code == 200
    assert sent == [("bld_007", body["message"])]

    r = await client.post("/internal/ai/echo", json={"x": 1}, headers=key)
    assert (r.status_code, r.json()) == (200, {"echo": {"x": 1}})
    assert (await client.post("/internal/ai/nope", json={}, headers=key)).status_code == 404


async def test_internal_endpoints_are_off_in_single_mode(client):
    r = await client.post("/internal/cluster/broadcast", json={"building_id": "bld_007", "message": {}},
                          headers={cluster.KEY_HEADER: ""})
    assert r.status_code == 404
    garbage = await client.post("/internal/ai/brief", content=b"{not json", headers={"content-type": "application/json"})
    assert garbage.status_code == 404  # no 422: nothing tells a stranger the endpoint exists


async def test_internal_endpoints_refuse_odd_keys_and_bodies(client, triple):
    odd = await client.post("/internal/cluster/broadcast", content=b"{}",
                            headers={cluster.KEY_HEADER: b"caf\xe9"})
    assert odd.status_code == 404  # a non-ASCII key is a mismatch, not a server error
    key = {cluster.KEY_HEADER: SECRET, "content-type": "application/json"}
    assert (await client.post("/internal/cluster/broadcast", content=b"[1]", headers=key)).status_code == 422
    assert (await client.post("/internal/cluster/broadcast", content=b'{"message": {}}', headers=key)).status_code == 422


async def test_broadcasts_reach_every_pi_not_known_dead_and_alarms_are_retried(triple, monkeypatch):
    posted: list[tuple[str, dict]] = []
    refusals = {"10.0.0.12": 2}  # the web Pi refuses twice (e.g. restarting), then takes it

    async def fake_post(host: str, port: int, path: str, body: bytes, timeout: float) -> bytes:
        if refusals.get(host):
            refusals[host] -= 1
            raise ConnectionRefusedError(host)
        posted.append((f"{host}:{port}{path}", json.loads(body)))
        return b"{}"

    monkeypatch.setattr(cluster, "_http_post", fake_post)
    monkeypatch.setattr(cluster, "FORWARD_PAUSE_S", 0)
    monkeypatch.setattr(manager, "forwarder", cluster.forward)
    # just after a database outage the last round saw only this Pi alive: still forward to both
    monkeypatch.setattr(cluster, "_alive", {"processing": T0})
    await manager.broadcast("bld_007", {"type": "incident"})
    await asyncio.gather(*cluster._forwards)
    frame = {"building_id": "bld_007", "message": {"type": "incident"}}
    assert sorted(posted) == [("10.0.0.12:8000/internal/cluster/broadcast", frame),
                              ("10.0.0.13:8000/internal/cluster/broadcast", frame)]

    posted.clear()
    monkeypatch.setattr(cluster, "_silent", {"ai"})  # unheard for a minute: a dead Pi
    await manager.broadcast("bld_007", {"type": "incident"})
    await asyncio.gather(*cluster._forwards)
    assert [url for url, _ in posted] == ["10.0.0.12:8000/internal/cluster/broadcast"]


async def test_call_peer_speaks_http_to_a_real_server(triple):
    """call_peer's own HTTP/1.1 against a real (stdlib) server: body, key header, errors."""
    seen: dict = {}

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        head = await reader.readuntil(b"\r\n\r\n")
        length = int(next(line.split(b":")[1] for line in head.split(b"\r\n") if line.lower().startswith(b"content-length")))
        seen["head"], seen["body"] = head, await reader.readexactly(length)
        ok = b"/ok" in head.split(b"\r\n")[0]
        answer = b'{"pong": 1}'
        writer.write((b"HTTP/1.1 200 OK" if ok else b"HTTP/1.1 503 Busy") + b"\r\nContent-Length: "
                     + str(len(answer)).encode() + b"\r\n\r\n" + answer)
        await writer.drain()
        writer.close()

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    base = f"http://127.0.0.1:{server.sockets[0].getsockname()[1]}"
    async with server:
        assert await cluster.call_peer(base, "/ok", {"x": 1}, 2) == {"pong": 1}
        assert seen["body"] == b'{"x":1}' and f"{cluster.KEY_HEADER}: {SECRET}".encode() in seen["head"]
        with pytest.raises(ConnectionError):
            await cluster.call_peer(base, "/busy", {}, 2)
    with pytest.raises(OSError):  # nobody listens there any more
        await cluster.call_peer(base, "/ok", {}, 2)


async def test_ai_work_goes_to_the_first_alive_pi_of_its_order(triple, monkeypatch):
    monkeypatch.setattr(cluster, "_alive", {"processing": T0, "web": T0, "ai": T0})
    assert cluster.ai_peer() == "http://10.0.0.13:8000"
    monkeypatch.setattr(cluster, "_alive", {"processing": T0, "web": T0})
    assert cluster.ai_peer() is None  # the AI Pi is down: this (processing) Pi computes itself


async def test_status_single_mode(client):
    hdr = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    body = (await client.get("/api/v1/cluster", headers=hdr)).json()
    assert (body["mode"], body["processing_node"], body["degraded"]) == ("single", "hub", False)
    assert body["nodes"][0]["roles"] == ["web", "processing", "ai"]
    resident = {"Authorization": f"Bearer {await auth_token(client, 'ana')}"}
    assert (await client.get("/api/v1/cluster", headers=resident)).status_code == 403


async def test_status_shows_who_took_over(client, triple):
    hailo = {"kind": "hailo-ollama", "online": True, "model": "qwen2.5-instruct:1.5b"}
    async with SessionLocal() as s:
        s.add_all([
            ClusterNode(name="processing", last_seen_ts=T0 - timedelta(minutes=1), up_since_ts=T0 - timedelta(hours=1),
                        info={"vip": False, "accelerator": None}),
            ClusterNode(name="web", last_seen_ts=T0, up_since_ts=T0 - timedelta(hours=1),
                        info={"vip": True, "accelerator": None}),
            ClusterNode(name="ai", last_seen_ts=T0, up_since_ts=T0 - timedelta(hours=1),
                        info={"vip": False, "accelerator": hailo}),
            ClusterLease(role="processing", holder="web", expires_ts=T0 + timedelta(seconds=5), acquired_ts=T0),
        ])
        await s.commit()
    hdr = {"Authorization": f"Bearer {await auth_token(client, 'admin')}"}
    body = (await client.get("/api/v1/cluster", headers=hdr)).json()
    assert (body["processing_node"], body["ai_node"], body["vip"], body["degraded"]) == ("web", "ai", "10.0.0.10", True)
    nodes = {n["name"]: n for n in body["nodes"]}
    assert (nodes["processing"]["alive"], nodes["processing"]["roles"]) == (False, [])
    assert (nodes["web"]["roles"], nodes["web"]["vip"]) == (["web", "processing"], True)
    assert (nodes["ai"]["roles"], nodes["ai"]["accelerator"]) == (["ai"], hailo)
