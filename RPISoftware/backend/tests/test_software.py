"""Hub software updates (app.software): the backend only relays to each Pi's canary-updater."""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app import software
from app.config import settings
from app.db import SessionLocal
from app.models import AuditLogEntry
from app.seed import TECH_ID
from tests.conftest import auth_token

OLD, NEW = "a" * 40, "b" * 40
IPS = {"processing": "10.0.0.11", "web": "10.0.0.12", "ai": "10.0.0.13"}


def pi_status(node, **kw):
    return {"node": node, "commit": {"sha": OLD, "subject": "old", "date": "2026-11-01T10:00:00Z"}, "branch": "main",
            "dirty": False, "behind": 1, "ahead": 0, "state": "idle", "step": None, "target": None, "previous": None,
            "error": None, "log": [], "rollout": None, "restart_needed": False,
            "fetched_at": "2026-11-02T10:00:00Z", "fetch_error": None, **kw}


@pytest.fixture
def helpers(monkeypatch):
    """host -> {(method, path): (status, body)}; every call is recorded."""
    monkeypatch.setattr(settings, "updater_key", "k")
    table: dict[str, dict[tuple[str, str], tuple[int, dict]]] = {}
    calls: list[tuple[str, str, str, dict | None]] = []

    async def fake(host, method, path, body=None, timeout=2.0):
        calls.append((host, method, path, body))
        return table.get(host, {}).get((method, path), (0, {}))

    monkeypatch.setattr(software, "call", fake)
    return table, calls


@pytest.fixture
def triple(monkeypatch):
    for key, value in {"cluster_mode": "triple", "node_name": "processing", "processing_ip": IPS["processing"],
                       "web_ip": IPS["web"], "ai_ip": IPS["ai"], "cluster_secret": "s"}.items():
        monkeypatch.setattr(settings, key, value)


def single_hub(table, **kw):
    table["host.docker.internal"] = {
        ("GET", "/status"): (200, pi_status("hub", **kw)),
        ("GET", "/incoming"): (200, {"head": {"sha": NEW, "subject": "new", "date": "2026-11-02T11:00:00Z"},
                                     "commits": [{"sha": NEW, "subject": "new", "author": "Gabi",
                                                  "date": "2026-11-02T11:00:00Z"}]}),
    }


async def hdr(client, user="tehnician"):
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def test_requires_staff_role(client, helpers):
    single_hub(helpers[0])
    assert (await client.get("/api/v1/hub/software", headers=await hdr(client, "ana"))).status_code == 403
    for user in ("tehnician", "mihai", "admin"):
        assert (await client.get("/api/v1/hub/software", headers=await hdr(client, user))).status_code == 200


async def test_unconfigured_reports_not_configured(client, helpers, monkeypatch):
    monkeypatch.setattr(settings, "updater_key", "")
    body = (await client.get("/api/v1/hub/software", headers=await hdr(client))).json()
    assert body["configured"] is False
    assert body["nodes"] == [{"name": "hub", "ip": None, "reachable": False, "status": None}]
    assert helpers[1] == []
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "hub", "commit": NEW},
                             headers=await hdr(client))
    assert (resp.status_code, resp.json()["detail"]) == (503, "updater key not configured")


async def test_overview_single_mode(client, helpers):
    single_hub(helpers[0])
    body = (await client.get("/api/v1/hub/software", headers=await hdr(client))).json()
    assert (body["configured"], body["mode"]) == (True, "single")
    assert body["github"] == {"head": {"sha": NEW, "subject": "new", "date": "2026-11-02T11:00:00Z"},
                              "fetched_at": "2026-11-02T10:00:00Z", "fetch_error": None}
    assert body["incoming"][0]["sha"] == NEW
    node = body["nodes"][0]
    assert (node["name"], node["reachable"], node["status"]["commit"]["sha"]) == ("hub", True, OLD)
    assert body["rollout"] is None


async def test_overview_triple_picks_most_behind_and_running_rollout(client, helpers, triple):
    table, _ = helpers
    running = {"commit": NEW, "order": ["ai", "web", "processing"], "results": {}, "outcome": "running",
               "reason": None, "started_at": "2026-11-02T11:00:00Z", "current": "ai"}
    old = {**running, "outcome": "done", "started_at": "2026-11-02T12:00:00Z"}
    table[IPS["processing"]] = {("GET", "/status"): (200, pi_status("processing", behind=0, rollout=running,
                                                                     fetched_at="2026-11-02T09:00:00Z")),
                                ("GET", "/incoming"): (200, {"head": None, "commits": []})}
    table[IPS["web"]] = {("GET", "/status"): (200, pi_status("web", behind=2, rollout=old)),
                         ("GET", "/incoming"): (200, {"head": {"sha": NEW}, "commits": [{"sha": NEW}, {"sha": "c" * 40}]})}
    body = (await client.get("/api/v1/hub/software", headers=await hdr(client))).json()
    assert [n["name"] for n in body["nodes"]] == ["processing", "web", "ai"]
    assert len(body["incoming"]) == 2
    assert body["github"]["fetched_at"] == "2026-11-02T10:00:00Z"
    assert body["rollout"]["outcome"] == "running"


async def test_unreachable_helper_marked(client, helpers, triple):
    body = (await client.get("/api/v1/hub/software", headers=await hdr(client))).json()
    ai = next(n for n in body["nodes"] if n["name"] == "ai")
    assert (ai["ip"], ai["reachable"], ai["status"]) == (IPS["ai"], False, None)


async def test_update_all_goes_to_own_pi_as_rollout(client, helpers, triple):
    table, calls = helpers
    table[IPS["processing"]] = {("POST", "/rollout"): (202, pi_status("processing"))}
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "all", "commit": NEW},
                             headers=await hdr(client))
    assert resp.status_code == 200, resp.text
    assert (IPS["processing"], "POST", "/rollout", {"commit": NEW}) in calls


async def test_update_one_goes_to_that_pi(client, helpers, triple):
    table, calls = helpers
    table[IPS["ai"]] = {("POST", "/update"): (202, pi_status("ai"))}
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "ai", "commit": NEW},
                             headers=await hdr(client))
    assert resp.status_code == 200
    assert (IPS["ai"], "POST", "/update", {"commit": NEW}) in calls


async def test_update_rejects_bad_commit_and_scope(client, helpers, triple):
    h = await hdr(client)
    for body in ({"scope": "ai", "commit": "main"}, {"scope": "hub", "commit": NEW}, {"scope": "ai"}):
        assert (await client.post("/api/v1/hub/software/update", json=body, headers=h)).status_code == 422
    assert helpers[1] == []


async def test_helper_refusal_passes_through(client, helpers, triple):
    helpers[0][IPS["web"]] = {("POST", "/update"): (409, {"error": "this Pi has local changes"})}
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "web", "commit": NEW},
                             headers=await hdr(client))
    assert (resp.status_code, resp.json()["detail"]) == (409, "this Pi has local changes")


async def test_unreachable_helper_is_503(client, helpers, triple):
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "web", "commit": NEW},
                             headers=await hdr(client))
    assert (resp.status_code, resp.json()["detail"]) == (503, "the web Pi's updater does not answer")


async def test_update_writes_audit_entry(client, helpers):
    single_hub(helpers[0])
    helpers[0]["host.docker.internal"][("POST", "/update")] = (202, pi_status("hub", state="updating"))
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "hub", "commit": NEW},
                             headers=await hdr(client))
    assert resp.status_code == 200
    async with SessionLocal() as s:
        entry = (await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action == "software_update"))).one()
    assert (entry.target, entry.detail, entry.actor) == ("hub", {"commit": NEW}, TECH_ID)


async def test_dismiss_forwards(client, helpers, triple):
    table, calls = helpers
    table[IPS["ai"]] = {("POST", "/dismiss"): (200, pi_status("ai"))}
    resp = await client.post("/api/v1/hub/software/dismiss", json={"name": "ai"}, headers=await hdr(client))
    assert resp.status_code == 200
    assert (IPS["ai"], "POST", "/dismiss", None) in calls


async def test_fetch_asks_every_helper(client, helpers, triple):
    _, calls = helpers
    await client.post("/api/v1/hub/software/fetch", headers=await hdr(client))
    assert {(h, p) for h, m, p, _ in calls if m == "POST"} == {(ip, "/fetch") for ip in IPS.values()}


async def test_call_speaks_http_with_the_key(monkeypatch):
    monkeypatch.setattr(settings, "updater_key", "k")
    seen = {}

    async def handle(reader, writer):
        seen["head"] = (await reader.readuntil(b"\r\n\r\n")).decode()
        writer.write(b'HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{"error": "busy"}')
        await writer.drain()
        writer.close()

    import asyncio
    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    monkeypatch.setattr(settings, "updater_port", server.sockets[0].getsockname()[1])
    async with server:
        assert await software.call("127.0.0.1", "GET", "/status") == (409, {"error": "busy"})
    assert seen["head"].startswith("GET /status HTTP/1.1")
    assert "X-Canary-Updater-Key: k" in seen["head"]
    monkeypatch.setattr(settings, "updater_port", 1)  # nothing listens there
    assert await software.call("127.0.0.1", "GET", "/status", timeout=1) == (0, {})


async def test_head_comes_from_the_pi_that_fetched_last(client, helpers, triple):
    table, _ = helpers
    table[IPS["processing"]] = {("GET", "/status"): (200, pi_status("processing", behind=3, fetched_at="2026-11-02T08:00:00Z")),
                                ("GET", "/incoming"): (200, {"head": {"sha": OLD}, "commits": []})}
    table[IPS["web"]] = {("GET", "/status"): (200, pi_status("web", behind=1, fetched_at="2026-11-02T10:00:00Z")),
                         ("GET", "/incoming"): (200, {"head": {"sha": NEW}, "commits": [{"sha": NEW}]})}
    body = (await client.get("/api/v1/hub/software", headers=await hdr(client))).json()
    assert body["github"]["head"]["sha"] == NEW
    assert body["incoming"] == [{"sha": NEW}]


async def test_rollout_relay_waits_for_the_peer_checks(client, helpers, triple, monkeypatch):
    table, _ = helpers
    seen = {}

    async def fake(host, method, path, body=None, timeout=2.0):
        seen[path] = timeout
        return (202, {}) if path == "/rollout" else (0, {})

    monkeypatch.setattr(software, "call", fake)
    resp = await client.post("/api/v1/hub/software/update", json={"scope": "all", "commit": NEW},
                             headers=await hdr(client))
    assert resp.status_code == 200
    assert seen["/rollout"] >= 50
