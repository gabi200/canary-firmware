"""Test config: SQLite-backed app, no MQTT. Env is set BEFORE importing app modules
so the cached Settings pick up the test database."""

from __future__ import annotations

import os
import pathlib

os.environ.setdefault("CANARY_DATABASE_URL", "sqlite+aiosqlite:///./test_canary.db")
os.environ["CANARY_MQTT_ENABLED"] = "false"
os.environ["CANARY_AUTO_CREATE_SCHEMA"] = "false"
os.environ["CANARY_AUTO_SEED"] = "false"
os.environ["CANARY_JWT_SECRET"] = "test-secret"

import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402

from app.db import SessionLocal, engine, init_db  # noqa: E402
from app.main import app  # noqa: E402
from app.seed import seed  # noqa: E402

_DB_FILE = pathlib.Path("./test_canary.db")


@pytest_asyncio.fixture
async def client() -> AsyncClient:
    if _DB_FILE.exists():
        _DB_FILE.unlink()
    await init_db()
    async with SessionLocal() as session:
        await seed(session)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c

    await engine.dispose()
    if _DB_FILE.exists():
        _DB_FILE.unlink()


async def auth_token(client: AsyncClient, username: str) -> str:
    resp = await client.post("/api/v1/auth/token", json={"username": username})
    assert resp.status_code == 200, resp.text
    return resp.json()["access_token"]


def telemetry(device_id: str, sensor_type: str, value: float, *, zone_id: str, unit_id: str,
              epoch: int = 1, seq: int = 1, units: str = "ppm", edge_state: str = "normal") -> dict:
    return {
        "schema": "canary.telemetry.v1",
        "device_id": device_id,
        "sensor_type": sensor_type,
        "location": {"building_id": "bld_007", "floor_id": "flr_03", "unit_id": unit_id, "zone_id": zone_id},
        "value": value,
        "units": units,
        "edge_state": edge_state,
        "epoch": epoch,
        "seq": seq,
    }
