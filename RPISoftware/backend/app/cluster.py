"""One Pi or three: membership, the processing lease and node-to-node calls (RUNME.md section 3).

`single` (default): this process does everything, as before; nothing here runs.

`triple`: three Pis share one Postgres (Patroni) and each runs this backend. Every node heartbeats
into `cluster_nodes`; the singleton processing workloads (MQTT subscription, retention, escalation
resume) run on whichever node holds the `processing` lease in `cluster_leases`; AI tasks go to the
first alive node of AI_ORDER. Times are the database server's clock: Pis may have no RTC and drift
apart, the primary's clock is the one every node agrees on.

Lease safety: the holder renews every TICK_S and stops its workloads when it could not renew for
RENEW_DEADLINE_S, before the lease (LEASE_TTL_S) can expire and another node take it. The MQTT
subscription also uses one fixed client id, so the broker itself kicks a second subscriber.
"""

from __future__ import annotations

import asyncio
import contextlib
import hmac
import json
import logging
import time
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit

from sqlalchemy import select, text, type_coerce, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql import func

from app.config import settings
from app.db import SessionLocal, engine
from app.models import ClusterLease, ClusterNode, UTCDateTime

log = logging.getLogger("canary.cluster")

NODES = ("processing", "web", "ai")
PROCESSING = "processing"  # the lease's role name
PROCESSING_ORDER = ("processing", "web", "ai")  # who takes the processing lease, best first
AI_ORDER = ("ai", "processing", "web")
API_PORT = 8000

TICK_S = 2.0
NODE_TTL_S = 10.0  # a node unheard for this long is down
LEASE_TTL_S = 15.0
# + one tick < LEASE_TTL_S: the old holder stops before anyone can take over. Commits stall ~5 s
# when the Pi with Postgres' synchronous standby dies; that must not stop processing.
RENEW_DEADLINE_S = 10.0
FAILBACK_S = 30.0  # the home node takes its role back once it has been up this long
FORWARD_TIMEOUT_S = 2.0
FORWARD_ATTEMPTS = 3
FORWARD_PAUSE_S = 0.5
PEER_SILENT_S = 60.0  # events are no longer forwarded to a Pi unheard for this long (or never seen)
SKEW_WARN_S = 2.0  # this Pi's clock against the database's: timestamps from different Pis get mixed
KEY_HEADER = "X-Canary-Cluster-Key"
_SCHEMA_LOCK = 7_243_001  # pg_advisory_lock key: one node creates the schema and seeds at a time


def triple() -> bool:
    return settings.cluster_mode == "triple"


def node_name() -> str:
    return settings.node_name if triple() else "hub"


def node_ips() -> dict[str, str]:
    return {"processing": settings.processing_ip, "web": settings.web_ip, "ai": settings.ai_ip}


def check_config() -> None:
    """Refuse to start a triple node with a half-written .env (scripts/pi_setup.sh writes it)."""
    if not triple():
        return
    if settings.node_name not in NODES:
        raise RuntimeError(f"CANARY_NODE_NAME must be one of {', '.join(NODES)} in triple mode")
    if not all(node_ips().values()) or not settings.cluster_secret:
        raise RuntimeError("triple mode needs CANARY_PROCESSING_IP, CANARY_WEB_IP, CANARY_AI_IP and "
                           "CANARY_CLUSTER_SECRET (run scripts/pi_setup.sh --cluster)")
    if not settings.database_url.startswith("postgresql"):
        raise RuntimeError("triple mode needs the shared Postgres: CANARY_DATABASE_URL=postgresql+asyncpg://...")


# --------------------------------------------------------------------------- #
# Live view of the cluster, refreshed by `run` every tick
# --------------------------------------------------------------------------- #
_alive: dict[str, datetime] = {}  # alive node -> up since (DB time)
_silent: set[str] = set()  # nodes unheard for PEER_SILENT_S or never seen; empty until a first round
_holds_processing = False
_skewed = False  # the clock-skew warning is out
_INSTANCE = uuid.uuid4().hex  # this process, to notice two Pis configured with the same name


def holds_processing() -> bool:
    return _holds_processing or not triple()


def first_alive(order: tuple[str, ...], alive: Mapping[str, datetime]) -> str | None:
    return next((n for n in order if n in alive), None)


def ai_peer() -> str | None:
    """Base URL of the node AI work goes to, or None to compute here."""
    if not triple():
        return None
    target = first_alive(AI_ORDER, _alive)
    if target is None or target == settings.node_name:
        return None
    return f"http://{node_ips()[target]}:{API_PORT}"


def desired_holder(
    order: tuple[str, ...], alive: Mapping[str, datetime], holder: str | None, now: datetime
) -> str | None:
    """Who should hold a lease: the best alive node, except that a live holder keeps it until the
    better node has been up FAILBACK_S (no flapping while a rebooted Pi settles)."""
    holder_alive = holder in alive
    for name in order:
        if name not in alive:
            continue
        if name == holder or not holder_alive or (now - alive[name]).total_seconds() >= FAILBACK_S:
            return name
    return None


# --------------------------------------------------------------------------- #
# Database side: heartbeat and lease, all on the DB server's clock
# --------------------------------------------------------------------------- #
async def db_now(session: AsyncSession) -> datetime:
    return await session.scalar(select(type_coerce(func.current_timestamp(), UTCDateTime)))


async def wait_for_db() -> None:
    """Block until the database answers: Patroni may still be electing a primary at boot."""
    attempt = 0
    while True:
        try:
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
            return
        except Exception as exc:  # noqa: BLE001 - not up yet: keep waiting, /health stays down meanwhile
            if attempt % 10 == 0:
                log.warning("waiting for the database: %s", exc)
            attempt += 1
            await asyncio.sleep(3)


@contextlib.asynccontextmanager
async def schema_lock() -> AsyncIterator[None]:
    """Serialize schema creation and seeding across nodes starting together (Postgres only)."""
    if not settings.is_postgres:
        yield
        return
    async with engine.connect() as conn:
        await conn.execute(text(f"SELECT pg_advisory_lock({_SCHEMA_LOCK})"))
        await conn.commit()
        try:
            yield
        finally:
            await conn.execute(text(f"SELECT pg_advisory_unlock({_SCHEMA_LOCK})"))
            await conn.commit()


def _vrrp_state() -> str | None:
    """MASTER / BACKUP / FAULT / STOP as last written by keepalived (None: no keepalived)."""
    try:
        with open(settings.vrrp_state_file, encoding="ascii") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def _accelerator() -> dict | None:
    try:
        from app.ai import llm
    except ImportError:
        return None
    return llm.accelerator_status()


async def _heartbeat(session: AsyncSession, now: datetime) -> None:
    global _skewed
    skew = round((datetime.now(timezone.utc) - now).total_seconds(), 1)
    if abs(skew) > SKEW_WARN_S and not _skewed:
        log.warning("this Pi's clock is %+.1f s off the database's: keep the three Pis on NTP (RUNME.md 3.1)", skew)
    _skewed = abs(skew) > SKEW_WARN_S
    info = {"vip": _vrrp_state() == "MASTER", "accelerator": _accelerator(), "instance": _INSTANCE,
            "clock_skew_s": skew}
    row = await session.get(ClusterNode, settings.node_name)
    if row is None:
        session.add(ClusterNode(name=settings.node_name, last_seen_ts=now, up_since_ts=now, info=info))
        return
    fresh = (now - row.last_seen_ts).total_seconds() <= NODE_TTL_S
    if fresh and row.info.get("instance") not in (None, _INSTANCE):
        # Two Pis claim the same name (a copied .env without re-running scripts/pi_setup.sh): both
        # would renew the same lease. Stay out until the other one is silent for NODE_TTL_S.
        raise RuntimeError(f"another Pi is already running as {settings.node_name!r}: check CANARY_NODE_NAME")
    if not fresh:
        row.up_since_ts = now  # back after a restart or an outage: up since now
    row.last_seen_ts, row.info = now, info


async def _views(session: AsyncSession, now: datetime) -> tuple[dict[str, datetime], set[str]]:
    """(alive node -> up since, nodes unheard for PEER_SILENT_S or never seen)."""
    rows = {r.name: r for r in await session.scalars(select(ClusterNode))}
    age = {name: (now - r.last_seen_ts).total_seconds() for name, r in rows.items()}
    alive = {name: rows[name].up_since_ts for name, seconds in age.items() if seconds <= NODE_TTL_S}
    return alive, {name for name in NODES if age.get(name, PEER_SILENT_S + 1) > PEER_SILENT_S}


async def _hold(session: AsyncSession, now: datetime, take: bool) -> bool:
    """Renew our lease, or (`take`) take a free / expired one. Atomic: two nodes never both succeed."""
    me, expires = settings.node_name, now + timedelta(seconds=LEASE_TTL_S)
    lease = ClusterLease.__table__
    renewed = await session.execute(
        update(lease).where(lease.c.role == PROCESSING, lease.c.holder == me).values(expires_ts=expires)
    )
    if renewed.rowcount:
        return True
    if not take:
        return False
    taken = await session.execute(
        update(lease)
        .where(lease.c.role == PROCESSING, (lease.c.holder.is_(None)) | (lease.c.expires_ts < now))
        .values(holder=me, expires_ts=expires, acquired_ts=now)
    )
    if taken.rowcount:
        return True
    if await session.get(ClusterLease, PROCESSING) is not None:
        return False
    try:  # first start of a new cluster: the row does not exist yet
        async with session.begin_nested():
            session.add(ClusterLease(role=PROCESSING, holder=me, expires_ts=expires, acquired_ts=now))
    except IntegrityError:
        return False  # another node created it first
    return True


async def _release() -> None:
    try:
        async with SessionLocal() as session:
            lease = ClusterLease.__table__
            await session.execute(
                update(lease)
                .where(lease.c.role == PROCESSING, lease.c.holder == settings.node_name)
                .values(holder=None, expires_ts=await db_now(session))
            )
            await session.commit()
    except Exception as exc:  # noqa: BLE001 - the lease then just expires
        log.warning("releasing the processing lease failed: %s", exc)


async def _retire() -> None:
    """Graceful stop: look gone at once, so the others react now and a restarted process can take
    the name back without waiting NODE_TTL_S."""
    try:
        async with SessionLocal() as session:
            nodes = ClusterNode.__table__
            gone = await db_now(session) - timedelta(seconds=NODE_TTL_S + 1)
            await session.execute(update(nodes).where(nodes.c.name == settings.node_name).values(last_seen_ts=gone))
            await session.commit()
    except Exception as exc:  # noqa: BLE001 - then it just ages out
        log.warning("leaving the cluster cleanly failed: %s", exc)


async def _round(take: bool) -> tuple[bool, bool, bool]:
    """One heartbeat + lease round: (we should hold processing, we hold it, the valid lease is ours).
    `take` False: renew only, never take a free lease."""
    global _alive, _silent
    async with SessionLocal() as session:
        now = await db_now(session)
        await _heartbeat(session, now)
        alive, silent = await _views(session, now)
        lease = await session.get(ClusterLease, PROCESSING)
        holder = lease.holder if lease is not None and lease.expires_ts > now else None
        want = desired_holder(PROCESSING_ORDER, alive, holder, now) == settings.node_name
        held = want and await _hold(session, now, take)
        await session.commit()
    _alive, _silent = alive, silent
    return want, held, holder == settings.node_name


async def run(stop: asyncio.Event, start: Callable[[], Awaitable[None]], halt: Callable[[], Awaitable[None]]) -> None:
    """Heartbeat every TICK_S and run `start` / `halt` as this node gains / loses the processing lease."""
    global _holds_processing
    last_renew = began = 0.0
    # Until every node had a chance to heartbeat, only the home node may take a free lease: at a
    # cold start of all three Pis, or when the database is back after a failover (every node's
    # heartbeat restarts then), the others would otherwise grab it and hand it back 30 s later.
    last_ok = time.monotonic()
    settled_at = last_ok + NODE_TTL_S
    pending: asyncio.Task | None = None
    while not stop.is_set():
        tick = time.monotonic()
        if pending is None:
            began = tick  # the lease's DB time is taken after this, so the deadline errs early
            current = began - last_ok <= NODE_TTL_S  # our view of who is alive is not stale
            take = settings.node_name == PROCESSING_ORDER[0] or (current and began >= settled_at)
            pending = asyncio.create_task(_round(take))
        # Never wait on a round past one tick: a query to a powered-off primary hangs until its
        # timeout, and the self-fence below must still run before the lease can expire.
        await asyncio.wait({pending}, timeout=TICK_S)
        outcome = None
        if pending.done():
            done, pending = pending, None
            try:
                outcome = done.result()
            except Exception as exc:  # noqa: BLE001 - DB unreachable (e.g. Patroni failover)
                log.warning("cluster heartbeat failed: %r", exc)
            if outcome is not None and time.monotonic() - began >= RENEW_DEADLINE_S:
                outcome = None  # a round this slow says nothing about the lease any more
        if outcome is None:
            if _holds_processing and time.monotonic() - last_renew > RENEW_DEADLINE_S:
                log.error("could not renew the processing lease for %.0f s: stopping processing", RENEW_DEADLINE_S)
                _holds_processing = False
                await _guard(halt)
        else:
            want, held, ours = outcome
            if began - last_ok > NODE_TTL_S:
                settled_at = time.monotonic() + NODE_TTL_S  # back from an outage: settle as at a cold start
            last_ok = began
            if held:
                last_renew = began
            if _holds_processing and not held:
                log.warning("processing moves away from %s", settings.node_name)
                _holds_processing = False
                await _guard(halt)  # stop first, then let the lease go
                if ours:
                    await _release()
            elif held and not _holds_processing:
                log.warning("%s takes over processing", settings.node_name)
                _holds_processing = True
                await _guard(start)
                if time.monotonic() - last_renew > RENEW_DEADLINE_S:  # starting outlived the lease
                    log.error("starting processing took longer than the lease: stopping it again")
                    _holds_processing = False
                    await _guard(halt)
            elif ours and not want:
                await _release()  # a lease left over from a self-fence: hand it on now
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=max(0.0, TICK_S - (time.monotonic() - tick)))
    if pending is not None:
        pending.cancel()
        await asyncio.wait({pending}, timeout=1)
    if _holds_processing:
        _holds_processing = False
        await _guard(halt)
        await _release()
    await _retire()


async def _guard(step: Callable[[], Awaitable[None]]) -> None:
    try:
        await step()
    except Exception:  # noqa: BLE001 - the loop must survive a failing workload
        log.exception("cluster workload change failed")


# --------------------------------------------------------------------------- #
# Node-to-node HTTP: plain HTTP/1.1 on asyncio streams, so a dead or slow Pi costs a socket and a
# timeout, never one of the few worker threads the rest of the backend shares (asyncio.to_thread).
# --------------------------------------------------------------------------- #
async def _http_post(host: str, port: int, path: str, body: bytes, timeout: float) -> bytes:
    """POST JSON with the cluster key; the answer's body, or raises (timeout, refused, not 2xx)."""

    async def exchange() -> bytes:
        reader, writer = await asyncio.open_connection(host, port)
        try:
            writer.write(
                f"POST {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/json\r\n"
                f"{KEY_HEADER}: {settings.cluster_secret}\r\nContent-Length: {len(body)}\r\n"
                "Connection: close\r\n\r\n".encode() + body
            )
            await writer.drain()
            raw = await reader.read()  # the peer closes after its answer (Connection: close)
        finally:
            writer.close()
        head, _, payload = raw.partition(b"\r\n\r\n")
        parts = head.split(b" ", 2)
        status = int(parts[1]) if head.startswith(b"HTTP/") and len(parts) > 1 and parts[1].isdigit() else 0
        if not 200 <= status < 300:
            raise ConnectionError(f"{host}:{port}{path} answered {status or 'garbage'}")
        return payload

    return await asyncio.wait_for(exchange(), timeout)


async def call_peer(base_url: str, path: str, payload: dict, timeout: float) -> dict:
    """POST JSON to another node's internal API; raises on timeout, refusal or a non-2xx answer."""
    url = urlsplit(base_url)
    body = json.dumps(payload, separators=(",", ":")).encode()
    raw = await _http_post(url.hostname or "", url.port or API_PORT, path, body, timeout)
    return json.loads(raw) if raw else {}


def key_ok(key: str | None) -> bool:
    # bytes: a header with non-ASCII characters must be a mismatch, not a TypeError
    return triple() and bool(settings.cluster_secret) and hmac.compare_digest(
        (key or "").encode(), settings.cluster_secret.encode())


_forwards: set[asyncio.Task] = set()


def forward(building_id: str, message: dict) -> None:
    """A WebSocket broadcast made here, sent on to the other Pis (fire and forget): dashboards and
    phones connect to whichever Pi holds the VIP, events happen on any of them. Every Pi not known
    dead gets it (a just-restored database shows only the Pis that heartbeated since), retried:
    residents' phones raise the alarm from these frames."""
    peers = [(n, ip) for n, ip in node_ips().items() if n != settings.node_name and n not in _silent]
    if not peers:
        return
    body = json.dumps({"building_id": building_id, "message": message}, separators=(",", ":")).encode()
    frequent = message.get("type") == "node"  # sensor status; anything else (alarms) must arrive
    for name, ip in peers:
        task = asyncio.get_running_loop().create_task(_forward_one(name, ip, body, frequent))
        _forwards.add(task)
        task.add_done_callback(_forwards.discard)


async def _forward_one(name: str, ip: str, body: bytes, frequent: bool) -> None:
    error: Exception | None = None
    for attempt in range(FORWARD_ATTEMPTS):
        try:
            await _http_post(ip, API_PORT, "/internal/cluster/broadcast", body, FORWARD_TIMEOUT_S)
            return
        except Exception as exc:  # noqa: BLE001 - refused, timeout, not 2xx: try again
            error = exc
        if attempt + 1 < FORWARD_ATTEMPTS:
            await asyncio.sleep(FORWARD_PAUSE_S)
    (log.debug if frequent else log.warning)("event for the %s Pi lost after %d attempts: %r", name,
                                            FORWARD_ATTEMPTS, error)


# --------------------------------------------------------------------------- #
# Status for the dashboard (GET /api/v1/cluster)
# --------------------------------------------------------------------------- #
def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


async def status(session: AsyncSession) -> dict:
    if not triple():
        return {
            "mode": "single", "node": "hub", "vip": None, "processing_node": "hub", "ai_node": "hub",
            "degraded": False,
            "nodes": [{"name": "hub", "ip": None, "alive": True, "last_seen": _iso(datetime.now(timezone.utc)),
                       "roles": ["web", "processing", "ai"], "home_role": None, "vip": False,
                       "accelerator": _accelerator()}],
        }
    now = await db_now(session)
    rows = {r.name: r for r in await session.scalars(select(ClusterNode))}
    alive = {n: r.up_since_ts for n, r in rows.items() if (now - r.last_seen_ts).total_seconds() <= NODE_TTL_S}
    lease = await session.get(ClusterLease, PROCESSING)
    processing = lease.holder if lease is not None and lease.expires_ts > now else None
    ai = first_alive(AI_ORDER, alive)
    front = next((n for n in NODES if n in alive and rows[n].info.get("vip")), None)
    nodes = []
    for name, ip in node_ips().items():
        row = rows.get(name)
        holders = (("web", front), ("processing", processing), ("ai", ai))
        nodes.append({
            "name": name, "ip": ip, "alive": name in alive,
            "last_seen": _iso(row.last_seen_ts) if row is not None else None,
            "roles": [role for role, holder in holders if holder == name],
            "home_role": name, "vip": front == name,
            "accelerator": row.info.get("accelerator") if row is not None and name in alive else None,
            "clock_skew_s": row.info.get("clock_skew_s") if row is not None and name in alive else None,
        })
    return {
        "mode": "triple", "node": settings.node_name, "vip": settings.vip or None,
        "processing_node": processing, "ai_node": ai,
        "degraded": len(alive) < len(NODES) or (front, processing, ai) != ("web", "processing", "ai"),
        "nodes": nodes,
    }
