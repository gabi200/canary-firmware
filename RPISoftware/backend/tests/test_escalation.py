"""Signed escalation webhook (ARC / 112 partner): signature, retries, timeout, privacy, listing."""

from __future__ import annotations

import hashlib
import hmac
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from sqlalchemy import func, select

from app.config import settings
from app.db import SessionLocal
from app.models import AuditLogEntry, EscalationDelivery, Notification
from app.notify import escalation
from tests.conftest import auth_token, telemetry

SECRET = "test-escalation-secret"
NOTE = "Concentrator de oxigen in dormitorul din spate"
PAYLOAD_KEYS = {"schema", "event_id", "sent_ts", "building", "incident", "accounting", "priority"}
INCIDENT_KEYS = {"id", "state", "hazard_type", "severity", "opened_ts", "primary_zone_id", "primary_zone_label",
                 "est_source_zone_id", "est_source_zone_label", "triangulation_confidence", "signature_verdict"}


class Partner:
    """A local stand-in for the partner: records requests; per event, fails the first
    `fail_times` attempts with 500 and sleeps `delay_s` before answering."""

    def __init__(self, fail_times: int = 0, delay_s: float = 0.0) -> None:
        self.fail_times, self.delay_s = fail_times, delay_s
        self.requests: list[tuple[dict, bytes]] = []
        self._attempts: dict[str, int] = {}
        partner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                body = self.rfile.read(int(self.headers["Content-Length"]))
                headers = {k.lower(): v for k, v in self.headers.items()}
                partner.requests.append((headers, body))
                event = headers.get("x-canary-event", "")
                partner._attempts[event] = partner._attempts.get(event, 0) + 1
                if partner.delay_s:
                    time.sleep(partner.delay_s)
                code = 500 if partner._attempts[event] <= partner.fail_times else 200
                try:
                    self.send_response(code)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                except OSError:  # the hub already gave up (timeout)
                    pass

            def log_message(self, *args) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/canary"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def events(self) -> list[dict]:
        return [json.loads(body) for _, body in self.requests]


@pytest.fixture
def partner(monkeypatch):
    created: list[Partner] = []

    def start(**kwargs) -> Partner:
        p = Partner(**kwargs)
        created.append(p)
        monkeypatch.setattr(settings, "escalation_url", p.url)
        monkeypatch.setattr(settings, "escalation_secret", SECRET)
        return p

    monkeypatch.setattr(escalation, "RETRY_DELAYS_S", (0, 0.01, 0.01, 0.01))
    yield start
    for p in created:
        p.server.shutdown()
        p.server.server_close()


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _evacuating_incident(client) -> str:
    """Critical kitchen gas: the incident runs through escalation into evacuation."""
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    assert resp.status_code == 200, resp.text
    await escalation.drain()
    return resp.json()["incident_id"]


async def _deliveries(incident_id: str) -> list[EscalationDelivery]:
    async with SessionLocal() as s:
        rows = await s.scalars(select(EscalationDelivery).where(EscalationDelivery.incident_id == incident_id)
                               .order_by(EscalationDelivery.id))
        return list(rows.all())


async def test_without_a_url_nothing_is_sent(client):
    incident_id = await _evacuating_incident(client)
    assert await _deliveries(incident_id) == []
    async with SessionLocal() as s:  # the integration notification rows work exactly as before
        assert await s.scalar(select(func.count()).select_from(Notification)
                              .where(Notification.channel == "external")) > 0


async def test_events_are_signed_and_carry_no_personal_data(client, partner):
    p = partner()
    ana = await _hdr(client, "ana")
    await client.patch("/api/v1/me", json={"phone": "0744 555 666"}, headers=ana)
    resp = await client.post("/api/v1/me/care-profiles", headers=ana, json={
        "unit_id": "unit_0312", "display_name": "Bunica Maria", "is_self": False,
        "needs": ["wheelchair", "medical_device"], "note": NOTE, "consent": True})
    assert resp.status_code == 201, resp.text
    incident_id = await _evacuating_incident(client)

    assert p.requests, "no webhook arrived"
    for headers, body in p.requests:
        event = json.loads(body)
        ts = headers["x-canary-timestamp"]
        assert headers["content-type"] == "application/json" and headers["x-canary-event"] == event["event_id"]
        assert abs(time.time() - int(ts)) < 60
        expected = "sha256=" + hmac.new(SECRET.encode(), ts.encode() + b"." + body, hashlib.sha256).hexdigest()
        assert headers["x-canary-signature"] == expected
        assert set(event) == PAYLOAD_KEYS and set(event["incident"]) == INCIDENT_KEYS
        assert event["schema"] == "canary.escalation.v1"
        assert event["building"] == {"id": "bld_007", "name": "Demo", "address": "Str. Exemplu 12, Bucuresti"}
        assert (event["incident"]["id"], event["incident"]["hazard_type"]) == (incident_id, "combustible_gas")
        assert event["incident"]["primary_zone_label"] == "Bucătărie"
        assert set(event["accounting"]) == {"occupancy_total", "accounted", "unaccounted", "needs_help",
                                            "priority_awaiting"}
        assert event["priority"] == [{"unit_label": "Ap. 12", "floor_label": "Etaj 3",
                                      "needs": ["wheelchair", "medical_device"], "status": "unknown"}]
        text = body.decode()
        for personal in ("Bunica", "Maria", NOTE, "Ana", "Popescu", "+40", "0744"):
            assert personal not in text, personal
    states = [e["incident"]["state"] for e in p.events()]
    assert "evacuation" in states and set(states) <= {"escalation", "evacuation"}
    assert len({e["event_id"] for e in p.events()}) == len(states)  # one event per transition, no retries

    listing = (await client.get(f"/api/v1/incidents/{incident_id}/escalations",
                                headers=await _hdr(client, "dispecer"))).json()
    assert sorted((e["state"], e["attempts"], e["last_status"], e["last_error"], e["delivered"]) for e in listing) == \
        sorted((s, 1, 200, None, True) for s in states)
    assert all(set(e) == {"event_id", "state", "attempts", "last_status", "last_error", "delivered", "ts"}
               for e in listing)
    async with SessionLocal() as s:
        audit = (await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action.like("escalation_%")))).all()
    assert {a.action for a in audit} == {"escalation_sent"} and len(audit) == len(states)
    assert all(set(a.detail) == {"state", "attempts", "status_code"} for a in audit)


async def test_failed_attempts_are_retried_with_the_same_event_id(client, partner):
    p = partner(fail_times=2)
    incident_id = await _evacuating_incident(client)

    by_event: dict[str, int] = {}
    for headers, _ in p.requests:
        by_event[headers["x-canary-event"]] = by_event.get(headers["x-canary-event"], 0) + 1
    assert by_event and set(by_event.values()) == {3}  # 500, 500, 200 for every event
    rows = await _deliveries(incident_id)
    for event_id in by_event:
        attempts = [(r.attempt, r.status_code, r.delivered) for r in rows if r.event_id == event_id]
        assert attempts == [(1, 500, False), (2, 500, False), (3, 200, True)]
    listing = (await client.get(f"/api/v1/incidents/{incident_id}/escalations",
                                headers=await _hdr(client, "mihai"))).json()
    assert {(e["attempts"], e["last_status"], e["delivered"]) for e in listing} == {(3, 200, True)}


async def test_timeouts_give_up_after_four_attempts_without_touching_the_incident(client, partner, monkeypatch):
    partner(delay_s=0.5)
    monkeypatch.setattr(escalation, "TIMEOUT_S", 0.1)
    incident_id = await _evacuating_incident(client)

    listing = (await client.get(f"/api/v1/incidents/{incident_id}/escalations",
                                headers=await _hdr(client, "mihai"))).json()
    assert listing and {(e["attempts"], e["last_status"], e["last_error"], e["delivered"]) for e in listing} == {
        (4, None, "timeout", False)}
    async with SessionLocal() as s:
        actions = (await s.scalars(select(AuditLogEntry.action).where(AuditLogEntry.action.like("escalation_%")))).all()
    assert set(actions) == {"escalation_failed"} and len(actions) == len(listing)
    incident = (await client.get(f"/api/v1/incidents/{incident_id}", headers=await _hdr(client, "mihai"))).json()
    assert incident["state"] == "evacuation"


async def test_unreachable_partner_and_roles(client, partner, monkeypatch):
    partner()
    monkeypatch.setattr(settings, "escalation_url", "http://127.0.0.1:9/canary")  # discard port: refused
    monkeypatch.setattr(escalation, "RETRY_DELAYS_S", (0,))
    incident_id = await _evacuating_incident(client)
    listing = (await client.get(f"/api/v1/incidents/{incident_id}/escalations",
                                headers=await _hdr(client, "mihai"))).json()
    assert listing and all(not e["delivered"] and e["last_status"] is None and e["last_error"] for e in listing)

    url = f"/api/v1/incidents/{incident_id}/escalations"
    assert (await client.get(url, headers=await _hdr(client, "ana"))).status_code == 403
    assert (await client.get("/api/v1/incidents/nope/escalations",
                             headers=await _hdr(client, "mihai"))).status_code == 404


async def test_pending_events_survive_a_restart_and_old_ones_expire(client, partner, monkeypatch):
    import asyncio
    from datetime import datetime, timedelta, timezone

    from sqlalchemy import update

    from app.main import app, lifespan
    from app.models import EscalationOutbox

    p = partner(fail_times=1)
    monkeypatch.setattr(escalation, "RETRY_DELAYS_S", (0, 3600, 3600, 3600))  # the retry is an hour away
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    incident_id = resp.json()["incident_id"]

    async def outbox() -> list[EscalationOutbox]:
        async with SessionLocal() as s:
            return list((await s.scalars(select(EscalationOutbox).order_by(EscalationOutbox.event_id))).all())

    for _ in range(200):  # first attempt (500) made, the retry sleeping
        rows = await outbox()
        if rows and all(r.attempts == 1 for r in rows):
            break
        await asyncio.sleep(0.01)
    assert rows and all((r.status, r.attempts, r.sealed) == ("pending", 1, True) for r in rows)
    assert all(NOTE not in r.body and "combustible_gas" not in r.body for r in rows)  # sealed at rest
    await escalation.stop()  # the hub goes down mid-retry

    async with SessionLocal() as s:  # ...comes back later; one more event is far too old to send now
        await s.execute(update(EscalationOutbox).values(next_attempt_ts=datetime.now(timezone.utc)))
        s.add(EscalationOutbox(event_id="old-event", incident_id=incident_id, state="evacuation", body="{}",
                               next_attempt_ts=datetime.now(timezone.utc),
                               created_ts=datetime.now(timezone.utc) - timedelta(minutes=31)))
        await s.commit()
    async with lifespan(app):
        await escalation.drain()

    by_event: dict[str, list[tuple[dict, bytes]]] = {}
    for headers, body in p.requests:
        by_event.setdefault(headers["x-canary-event"], []).append((headers, body))
    assert set(by_event) == {r.event_id for r in rows} and "old-event" not in by_event
    for attempts in by_event.values():
        assert len(attempts) == 2 and attempts[0][1] == attempts[1][1]  # same event, original body
        for headers, body in attempts:
            ts = headers["x-canary-timestamp"]
            assert headers["x-canary-signature"] == "sha256=" + hmac.new(
                SECRET.encode(), ts.encode() + b"." + body, hashlib.sha256).hexdigest()
    settled = {r.event_id: (r.status, r.attempts, r.body) for r in await outbox()}
    assert settled.pop("old-event") == ("expired", 0, "")
    assert set(settled.values()) == {("delivered", 2, "")}
    async with SessionLocal() as s:
        expired = (await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action == "escalation_expired"))).all()
    assert [(a.target, a.incident_id) for a in expired] == [("old-event", incident_id)]
