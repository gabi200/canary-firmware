"""Is this Pi healthy: its containers, its backend and (three Pis) its Postgres member."""

from __future__ import annotations

import json

from updater.config import Config
from updater.runner import Runner

EXPECTED_SINGLE = ("mosquitto", "backend", "web")
EXPECTED_TRIPLE = EXPECTED_SINGLE + ("etcd", "postgres", "pgproxy", "keepalived")
PATRONI_PORT = 8008
API_PORT = 8000


def _compose_rows(text: str) -> list[dict]:
    """`docker compose ps --format json`: one JSON array (older Compose) or one object per line."""
    text = text.strip()
    if text.startswith("["):
        try:
            data = json.loads(text)
        except ValueError:
            return []
        return [d for d in data if isinstance(d, dict)]
    rows = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def compose_problem(cfg: Config, r: Runner) -> str | None:
    res = r.run(["docker", "compose", "ps", "-a", "--format", "json"], cwd=cfg.app_dir, timeout=30)
    if res.code != 0:
        return f"docker compose ps failed: {res.out.strip()[-200:]}"
    rows = {row.get("Service"): row for row in _compose_rows(res.out)}
    for service in EXPECTED_TRIPLE if cfg.triple else EXPECTED_SINGLE:
        row = rows.get(service)
        if row is None:
            return f"{service} is missing"
        if row.get("State") != "running":
            return f"{service} is {row.get('State') or 'not running'}"
        if row.get("Health", "") not in ("", "healthy"):
            return f"{service} is {row['Health']}"
    return None


def backend_problem(cfg: Config, r: Runner) -> str | None:
    status, body = r.http("GET", f"http://127.0.0.1:{API_PORT}/health", timeout=4)
    return None if status == 200 and body.get("status") == "ok" else "the backend does not answer /health"


def patroni_members(cfg: Config, r: Runner) -> list[dict] | None:
    for ip in cfg.peers.values():
        status, body = r.http("GET", f"http://{ip}:{PATRONI_PORT}/cluster", timeout=3)
        if status == 200 and isinstance(body.get("members"), list):
            return [m for m in body["members"] if isinstance(m, dict)]
    return None


def patroni_problem(cfg: Config, r: Runner) -> str | None:
    if not cfg.triple:
        return None
    members = patroni_members(cfg, r)
    if members is None:
        return "no Pi's Patroni answers"
    me = next((m for m in members if m.get("name") == cfg.node), None)
    if me is None:
        return "this Pi's database is not in the cluster"
    if me.get("state") not in ("running", "streaming"):
        return f"this Pi's database is {me.get('state')}"
    return None


def problem(cfg: Config, r: Runner) -> str | None:
    return compose_problem(cfg, r) or backend_problem(cfg, r) or patroni_problem(cfg, r)


def peer_problem(cfg: Config, r: Runner, name: str) -> str | None:
    status, body = r.http("GET", f"http://{cfg.peers[name]}:{API_PORT}/health", timeout=3)
    return None if status == 200 and body.get("status") == "ok" else f"the {name} Pi is not healthy"
