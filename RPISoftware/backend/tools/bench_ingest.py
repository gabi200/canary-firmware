"""Ingestion benchmark: 40 simulated nodes through the real status handler on a temp SQLite DB.

    .venv/bin/python -m tools.bench_ingest [--air 28] [--water 12] [--rounds 10] [--poll]

Reports ms per status document (p50 / p95 / max) and SQL statements per document, plus the
REST endpoints the dashboard polls (summary, nodes, 60-minute history). With --poll the
dashboard load runs concurrently (as on the live hub) and the report adds how long each
document waited behind it.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import shutil
import statistics
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

_DB_DIR = tempfile.mkdtemp(prefix="canary-bench-")
os.environ["CANARY_DATABASE_URL"] = f"sqlite+aiosqlite:///{_DB_DIR}/bench.db"
os.environ.update(CANARY_MQTT_ENABLED="false", CANARY_AUTO_CREATE_SCHEMA="false", CANARY_AUTO_SEED="false",
                  CANARY_JWT_SECRET="bench-secret-bench-secret-bench-secret")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy import event, update  # noqa: E402

from app.db import SessionLocal, engine, init_db  # noqa: E402
from app.ingestion.hardware import handle_hardware_message  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Device, Node  # noqa: E402
from app.seed import seed  # noqa: E402
from tests.hardware_docs import air_doc, water_doc  # noqa: E402

ZONES = ["zone_kitchen", "zone_bedroom", "zone_hallway", "zone_boiler"]
HISTORY_FIELDS = ("co.ppm,gas.adc,particulate.pm1_0,particulate.pm2_5,particulate.pm10,climate.temperature_c,"
                  "climate.humidity_percent,wifi.rssi,presence.detected,presence.moving,presence.stationary,uptime_ms")

statements: Counter[str] = Counter()
transactions: Counter[str] = Counter()


@event.listens_for(engine.sync_engine, "before_cursor_execute")
def _count(conn, cursor, statement, params, context, executemany):  # noqa: ANN001
    statements[" ".join(statement.split()[:4])[:60]] += 1


@event.listens_for(engine.sync_engine, "commit")
def _commit(conn):  # noqa: ANN001
    transactions["commit"] += 1


@event.listens_for(engine.sync_engine.pool, "checkout")
def _checkout(dbapi_conn, record, proxy):  # noqa: ANN001
    transactions["checkout"] += 1


def _doc(kind: str, i: int, uptime: int) -> bytes:
    rnd = random.Random(i * 1000 + uptime)
    if kind == "air":
        doc = air_doc(uptime_ms=uptime, co={"ppm": rnd.randint(1, 6)}, gas={"adc": rnd.randint(600, 700)},
                      particulate={"pm2_5": rnd.randint(3, 12), "pm10": rnd.randint(5, 20)},
                      climate={"temperature_c": round(rnd.uniform(21, 23), 1),
                               "humidity_percent": round(rnd.uniform(38, 46), 1)},
                      presence={"detected": rnd.random() < 0.3})
    else:
        doc = water_doc(uptime_ms=uptime, sensor={"adc": rnd.randint(280, 340)})
    return json.dumps(doc).encode()


def _pct(values: list[float], q: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


async def _setup(n_air: int, n_water: int, warm_rounds: int) -> list[tuple[str, str]]:
    await init_db()
    async with SessionLocal() as session:
        await seed(session)
    nodes = [(f"bench-air-{i:02d}", "air") for i in range(n_air)] + \
            [(f"bench-water-{i:02d}", "water") for i in range(n_water)]
    for i, (base, kind) in enumerate(nodes):
        await handle_hardware_message(f"{base}/status", _doc(kind, i, 1000))
    async with SessionLocal() as session:  # spread them over the building like the simulator
        for i, (base, _) in enumerate(nodes):
            zone = ZONES[i % len(ZONES)]
            await session.execute(update(Node).where(Node.mqtt_base == base).values(zone_id=zone))
            await session.execute(update(Device).where(Device.id.like(f"{base}:%")).values(zone_id=zone))
        await session.commit()
    for r in range(warm_rounds):  # an hour-ish of history for the history endpoint / trends
        for i, (base, kind) in enumerate(nodes):
            await handle_hardware_message(f"{base}/status", _doc(kind, i, 2000 + r * 15000))
    return nodes


async def _poll(client: AsyncClient, headers: dict, nodes: list[tuple[str, str]], stop: asyncio.Event,
                rest: dict[str, list[float]]) -> None:
    node_ids = [base for base, _ in nodes]
    while not stop.is_set():
        for name, url, params in (
            ("summary", "/api/v1/buildings/bld_007/summary", None),
            ("nodes", "/api/v1/buildings/bld_007/nodes", None),
            ("history", f"/api/v1/nodes/{random.choice(node_ids)}/history",
             {"minutes": 60, "fields": HISTORY_FIELDS}),
        ):
            t = time.perf_counter()
            resp = await client.get(url, params=params, headers=headers)
            assert resp.status_code == 200, resp.text
            rest[name].append((time.perf_counter() - t) * 1000)
        await asyncio.sleep(0)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--air", type=int, default=28)
    parser.add_argument("--water", type=int, default=12)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--warm", type=int, default=60, help="history rounds before measuring")
    parser.add_argument("--poll", action="store_true", help="run the dashboard polling load concurrently")
    args = parser.parse_args()

    nodes = await _setup(args.air, args.water, args.warm)
    transport = ASGITransport(app=app)
    rest: dict[str, list[float]] = {"summary": [], "nodes": [], "history": []}
    async with AsyncClient(transport=transport, base_url="http://bench") as client:
        token = (await client.post("/api/v1/auth/token", json={"username": "mihai"})).json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}
        stop = asyncio.Event()
        poller = asyncio.create_task(_poll(client, headers, nodes, stop, rest)) if args.poll else None

        per_doc: list[float] = []
        statements.clear()
        transactions.clear()
        cpu0 = time.process_time()
        uptime0 = 2000 + args.warm * 15000
        for r in range(args.rounds):
            for i, (base, kind) in enumerate(nodes):
                t = time.perf_counter()
                await handle_hardware_message(f"{base}/status", _doc(kind, i, uptime0 + r * 15000))
                per_doc.append((time.perf_counter() - t) * 1000)
                await asyncio.sleep(0)  # let the poller in, like the event loop would
        docs = len(per_doc)
        cpu_ms = (time.process_time() - cpu0) * 1000 / docs
        sql = sum(statements.values())
        tx = dict(transactions)
        if poller:
            stop.set()
            await poller
        if not args.poll:  # REST on its own
            for _ in range(5):
                stop = asyncio.Event()
                stop.set()
            for name, url, params in (
                ("summary", "/api/v1/buildings/bld_007/summary", None),
                ("nodes", "/api/v1/buildings/bld_007/nodes", None),
                ("history", f"/api/v1/nodes/{nodes[0][0]}/history", {"minutes": 60, "fields": HISTORY_FIELDS}),
            ):
                for _ in range(10):
                    t = time.perf_counter()
                    await client.get(url, params=params, headers=headers)
                    rest[name].append((time.perf_counter() - t) * 1000)

    print(f"{len(nodes)} nodes ({args.air} air, {args.water} water), {docs} status documents"
          f"{' with dashboard polling' if args.poll else ''}")
    print(f"  per document: p50 {_pct(per_doc, .5):.1f} ms  p95 {_pct(per_doc, .95):.1f} ms  "
          f"max {max(per_doc):.1f} ms  mean {statistics.mean(per_doc):.1f} ms")
    print(f"  CPU per document: {cpu_ms:.1f} ms (process time, all threads)")
    print(f"  SQL statements per document: {sql / docs:.1f}; commits {tx.get('commit', 0) / docs:.1f}; "
          f"connection checkouts {tx.get('checkout', 0) / docs:.1f}")
    for stmt, n in statements.most_common(8):
        print(f"    {n / docs:5.2f}  {stmt}")
    for name, values in rest.items():
        if values:
            print(f"  GET {name:8s}: p50 {_pct(values, .5):.1f} ms  p95 {_pct(values, .95):.1f} ms  (n={len(values)})")
    await engine.dispose()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    finally:
        shutil.rmtree(_DB_DIR, ignore_errors=True)
