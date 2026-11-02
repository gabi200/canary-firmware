"""Hub software updates: a relay to canary-updater, the helper on each Pi's host (cluster/updater).

The backend runs in Docker and an update rebuilds Docker, so it never runs git or docker itself: it
asks the helpers (port 8010, key CANARY_UPDATER_KEY) and merges their answers for the dashboard.
"""

from __future__ import annotations

import asyncio
import json
import re

from app import cluster
from app.config import settings

KEY_HEADER = "X-Canary-Updater-Key"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SINGLE_HOST = "host.docker.internal"  # the one-Pi hub's own host (extra_hosts in docker-compose.yml)


def helper_hosts() -> dict[str, str]:
    return cluster.node_ips() if cluster.triple() else {"hub": SINGLE_HOST}


async def call(host: str, method: str, path: str, body: dict | None = None, timeout: float = 2.0) -> tuple[int, dict]:
    """(status, JSON object) from a helper; status 0 when it cannot be reached or answers garbage.
    Plain asyncio streams, as app.cluster does: a dead Pi costs a socket and a timeout."""
    raw_body = json.dumps(body).encode() if body is not None else b""
    port = settings.updater_port

    async def exchange() -> bytes:
        reader, writer = await asyncio.open_connection(host, port)
        try:
            writer.write(
                f"{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/json\r\n"
                f"{KEY_HEADER}: {settings.updater_key}\r\nContent-Length: {len(raw_body)}\r\n"
                "Connection: close\r\n\r\n".encode() + raw_body
            )
            await writer.drain()
            return await reader.read()
        finally:
            writer.close()

    try:
        raw = await asyncio.wait_for(exchange(), timeout)
    except (OSError, asyncio.TimeoutError):
        return 0, {}
    head, _, payload = raw.partition(b"\r\n\r\n")
    parts = head.split(b" ", 2)
    if not head.startswith(b"HTTP/") or len(parts) < 2 or not parts[1].isdigit():
        return 0, {}
    try:
        data = json.loads(payload) if payload else {}
    except ValueError:
        data = {}
    return int(parts[1]), data if isinstance(data, dict) else {}


async def overview() -> dict:
    hosts = helper_hosts()
    triple = cluster.triple()
    result = {"configured": bool(settings.updater_key), "mode": "triple" if triple else "single",
              "github": {"head": None, "fetched_at": None, "fetch_error": None}, "incoming": [],
              "nodes": [], "rollout": None}
    if not settings.updater_key:
        result["nodes"] = [{"name": n, "ip": ip if triple else None, "reachable": False, "status": None}
                           for n, ip in hosts.items()]
        return result
    answers = await asyncio.gather(*(call(ip, "GET", "/status") for ip in hosts.values()))
    statuses: dict[str, dict] = {}
    for (name, ip), (status, body) in zip(hosts.items(), answers):
        ok = status == 200
        if ok:
            statuses[name] = body
        result["nodes"].append({"name": name, "ip": ip if triple else None, "reachable": ok,
                                "status": body if ok else None})
    if not statuses:
        return result
    # GitHub's head from the Pi that fetched last: the others' copy of origin/main may be older
    newest = max(statuses, key=lambda n: statuses[n].get("fetched_at") or "")
    status, incoming = await call(hosts[newest], "GET", "/incoming")
    if status == 200:
        result["github"]["head"] = incoming.get("head")
        result["incoming"] = incoming.get("commits") or []
    result["github"]["fetched_at"] = statuses[newest].get("fetched_at")
    result["github"]["fetch_error"] = statuses[newest].get("fetch_error")
    rollouts = [s["rollout"] for s in statuses.values() if isinstance(s.get("rollout"), dict)]
    running = [r for r in rollouts if r.get("outcome") == "running"]
    if running or rollouts:
        result["rollout"] = running[0] if running else max(rollouts, key=lambda r: r.get("started_at") or "")
    return result
