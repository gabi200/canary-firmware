"""Signed escalation webhook to the external partner (ARC / 112 dispatch), docs/HARDWARE.md section 4.

On every transition into an external state (escalation, evacuation, resolution) the event is
built inside the transition's transaction and sent only after that transaction commits (never
on rollback), by a background task that can never block or break the incident pipeline.

    POST CANARY_ESCALATION_URL
    Content-Type: application/json
    X-Canary-Event: <event_id>               (same on every retry: idempotency key)
    X-Canary-Timestamp: <unix seconds>       (per attempt)
    X-Canary-Signature: sha256=<hex HMAC-SHA256(CANARY_ESCALATION_SECRET, timestamp + "." + body)>

Up to 4 attempts (0 s, 5 s, 30 s, 120 s), 5 s timeout each; a 2xx is delivered. Every attempt is
a row in `escalation_deliveries`; the outcome is audited (`escalation_sent|escalation_failed`)
without payload content. The body never carries names, notes or phone numbers.

Restarts: the event (its original body, attempt count, next attempt time) is written to
`escalation_outbox` in the transition's own transaction. On startup `resume_pending` resumes
every pending event created in the last 30 minutes with the same event_id and body (timestamp
and signature are recomputed per attempt); older ones are marked expired and audited
`escalation_expired`. The stored body is Fernet-sealed with CANARY_CARE_KEY when set (it may
carry need codes) and cleared once the event is settled.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import socket
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit

from sqlalchemy import event, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.db import SessionLocal
from app.enums import IncidentState
from app.models import AuditLogEntry, Building, EscalationDelivery, EscalationOutbox, Incident, Zone

log = logging.getLogger("canary.escalation")

SCHEMA = "canary.escalation.v1"
RETRY_DELAYS_S: tuple[float, ...] = (0, 5, 30, 120)
TIMEOUT_S = 5.0
RESUME_WINDOW = timedelta(minutes=30)  # pending events older than this are expired at startup

_PENDING = "canary_escalations"  # session.info key: events waiting for the commit
_HOOKED = "canary_escalation_hooks"
_tasks: set[asyncio.Task] = set()


def _iso(ts: datetime | None) -> str | None:
    if ts is None:
        return None
    ts = ts.replace(tzinfo=timezone.utc) if ts.tzinfo is None else ts.astimezone(timezone.utc)
    return ts.isoformat().replace("+00:00", "Z")


def sign(secret: str, timestamp: str, body: bytes) -> str:
    """`sha256=<hex>` of HMAC-SHA256(secret, timestamp + "." + body)."""
    return "sha256=" + hmac.new(secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()


async def build_payload(session: AsyncSession, incident: Incident, state: IncidentState) -> dict:
    """The canary.escalation.v1 body: ids, labels, counts and need codes; no names, notes or phones."""
    from app.analytics.service import AnalyticsService  # deferred: analytics imports the incident spine
    from app.care import service as care
    from app.occupancy.service import OccupancyService

    building = await session.get(Building, incident.building_id)
    zone_ids = [z for z in (incident.primary_zone_id, incident.est_source_zone_id) if z]
    labels = dict((await session.execute(select(Zone.id, Zone.label).where(Zone.id.in_(zone_ids)))).all())
    acc = await OccupancyService(session).accounting(incident.id, incident.building_id)
    statuses = await care.priority_statuses(session, incident)
    people = await care.priority_people(session, statuses)
    signature = (await AnalyticsService(session).latest_signatures([incident.id])).get(incident.id)
    return {
        "schema": SCHEMA,
        "event_id": str(uuid.uuid4()),
        "sent_ts": _iso(datetime.now(timezone.utc)),
        "building": {
            "id": incident.building_id,
            "name": building.name if building else "",
            "address": building.address if building else "",
        },
        "incident": {
            "id": incident.id,
            "state": state.value,
            "hazard_type": incident.hazard_type,
            "severity": incident.severity,
            "opened_ts": _iso(incident.opened_ts),
            "primary_zone_id": incident.primary_zone_id,
            "primary_zone_label": labels.get(incident.primary_zone_id),
            "est_source_zone_id": incident.est_source_zone_id,
            "est_source_zone_label": labels.get(incident.est_source_zone_id),
            "triangulation_confidence": incident.triangulation_confidence,
            "signature_verdict": signature.label if signature is not None else None,
        },
        "accounting": {
            "occupancy_total": acc.occupancy_total,
            "accounted": acc.accounted,
            "unaccounted": acc.unaccounted,
            "needs_help": acc.needs_help,
            "priority_awaiting": care.awaiting(statuses),
        },
        "priority": [
            {"unit_label": p.unit_label, "floor_label": p.floor_label, "needs": p.needs, "status": p.status}
            for p in people
        ],
    }


# --------------------------------------------------------------------------- #
# Outbox: queued in the transition's transaction, sent after commit, resumed after a restart
# --------------------------------------------------------------------------- #
def _now() -> datetime:
    return datetime.now(timezone.utc)


def _seal(body: str) -> tuple[str, bool]:
    from app.care import service as care

    try:
        return care.cipher().encrypt(body.encode()).decode(), True
    except care.CareUnavailable:  # no key: priority carries no need codes either
        return body, False


def _unseal(row: EscalationOutbox) -> bytes:
    from app.care import service as care

    return care.cipher().decrypt(row.body.encode()) if row.sealed else row.body.encode()


async def queue(session: AsyncSession, incident: Incident, state: IncidentState) -> None:
    """Build the event and add it to the outbox in the caller's transaction; it is sent once that
    transaction commits (never on rollback). No-op without CANARY_ESCALATION_URL. Never raises."""
    if not settings.escalation_url:
        return
    try:
        payload = await build_payload(session, incident, state)
        body, sealed = _seal(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))
        now = _now()
        session.add(EscalationOutbox(
            event_id=payload["event_id"], incident_id=incident.id, state=state.value, body=body, sealed=sealed,
            attempts=0, status="pending", next_attempt_ts=now, created_ts=now,
        ))
    except Exception:  # noqa: BLE001 - the incident pipeline must not depend on the webhook
        log.exception("escalation event for incident %s failed", incident.id)
        return
    sync = session.sync_session
    sync.info.setdefault(_PENDING, []).append(payload["event_id"])
    if not sync.info.get(_HOOKED):
        sync.info[_HOOKED] = True
        event.listen(sync, "after_commit", _after_commit)
        event.listen(sync, "after_rollback", _after_rollback)


def _spawn(event_id: str) -> None:
    task = asyncio.get_running_loop().create_task(deliver(event_id))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


def _after_commit(sync_session) -> None:
    for event_id in sync_session.info.pop(_PENDING, []):
        _spawn(event_id)


def _after_rollback(sync_session) -> None:
    sync_session.info.pop(_PENDING, None)


async def resume_pending() -> None:
    """Startup: resume recent pending events, expire older ones. Never raises."""
    try:
        cutoff, resume = _now() - RESUME_WINDOW, []
        async with SessionLocal() as session:
            for row in (await session.scalars(select(EscalationOutbox).where(EscalationOutbox.status == "pending"))):
                if row.created_ts >= cutoff:
                    resume.append(row.event_id)
                    continue
                row.status, row.body = "expired", ""
                session.add(AuditLogEntry(incident_id=row.incident_id, actor="system", action="escalation_expired",
                                          target=row.event_id, detail={"state": row.state, "attempts": row.attempts}))
            await session.commit()
        for event_id in resume:
            _spawn(event_id)
        if resume:
            log.info("resumed %d pending escalation event(s)", len(resume))
    except Exception:  # noqa: BLE001
        log.exception("resuming escalation events failed")


async def drain() -> None:
    """Wait for every in-flight delivery (tests)."""
    while _tasks:
        await asyncio.gather(*list(_tasks), return_exceptions=True)


async def stop() -> None:
    """Shutdown: cancel in-flight deliveries; the outbox resumes them on the next start."""
    for task in list(_tasks):
        task.cancel()
    await asyncio.gather(*list(_tasks), return_exceptions=True)


# --------------------------------------------------------------------------- #
# Delivery
# --------------------------------------------------------------------------- #
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # a 3xx is a failed delivery, never followed
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def _post(url: str, body: bytes, headers: dict[str, str], timeout: float) -> int:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with _opener.open(request, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def _describe(exc: BaseException) -> str:
    reason = exc.reason if isinstance(exc, urllib.error.URLError) else exc
    if isinstance(reason, (TimeoutError, socket.timeout)):
        return "timeout"
    return f"{type(reason).__name__}: {reason}"[:200]


async def deliver(event_id: str) -> bool:
    """Send one outbox event until delivered or out of attempts; True once a 2xx arrives. Never raises."""
    try:
        return await _deliver(event_id)
    except asyncio.CancelledError:
        raise
    except Exception:  # noqa: BLE001
        log.exception("escalation delivery %s crashed", event_id)
        return False


async def _send(event_id: str, body: bytes) -> tuple[int | None, str | None, bool]:
    """(status code, error, retryable) for one signed POST."""
    url, secret = settings.escalation_url, settings.escalation_secret
    if urlsplit(url).scheme not in ("http", "https"):
        return None, "CANARY_ESCALATION_URL must be an http(s) URL", False
    if not secret:
        return None, "CANARY_ESCALATION_SECRET is not set (run scripts/pi_setup.sh)", False
    timestamp = str(int(time.time()))
    headers = {
        "Content-Type": "application/json",
        "X-Canary-Event": event_id,
        "X-Canary-Timestamp": timestamp,
        "X-Canary-Signature": sign(secret, timestamp, body),
        "User-Agent": "canary-hub/escalation",
    }
    try:
        return await asyncio.to_thread(_post, url, body, headers, TIMEOUT_S), None, True
    except Exception as exc:  # noqa: BLE001 - timeout, refused, DNS ...
        return None, _describe(exc), True


async def _deliver(event_id: str) -> bool:
    while True:
        async with SessionLocal() as session:
            row = await session.get(EscalationOutbox, event_id)
            if row is None or row.status != "pending":
                return row is not None and row.status == "delivered"
            wait_s = (row.next_attempt_ts - _now()).total_seconds()
            body = _unseal(row)
        if wait_s > 0:
            await asyncio.sleep(wait_s)
        code, error, retryable = await _send(event_id, body)
        delivered = code is not None and 200 <= code < 300
        async with SessionLocal() as session:
            row = await session.get(EscalationOutbox, event_id)
            row.attempts += 1
            final = delivered or not retryable or row.attempts >= len(RETRY_DELAYS_S)
            session.add(EscalationDelivery(event_id=event_id, incident_id=row.incident_id, state=row.state,
                                           attempt=row.attempts, status_code=code, error=error, delivered=delivered))
            if final:
                row.status, row.body = ("delivered" if delivered else "failed"), ""
                session.add(AuditLogEntry(
                    incident_id=row.incident_id, actor="system",
                    action="escalation_sent" if delivered else "escalation_failed", target=event_id,
                    detail={"state": row.state, "attempts": row.attempts, "status_code": code},
                ))
            else:
                row.next_attempt_ts = _now() + timedelta(seconds=RETRY_DELAYS_S[row.attempts])
                log.warning("escalation %s attempt %d failed: %s", event_id, row.attempts, error or code)
            await session.commit()
        if final:
            return delivered
