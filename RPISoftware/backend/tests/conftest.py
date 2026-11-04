"""Test config: SQLite-backed app, no MQTT. Env is set BEFORE importing app modules
so the cached Settings pick up the test database. A CANARY_DATABASE_URL of
postgresql+asyncpg://... runs the same suite against Postgres."""

from __future__ import annotations

import os
import pathlib

os.environ.setdefault("CANARY_DATABASE_URL", "sqlite+aiosqlite:///./test_canary.db")
os.environ["CANARY_MQTT_ENABLED"] = "false"
os.environ["CANARY_AUTO_CREATE_SCHEMA"] = "false"
os.environ["CANARY_AUTO_SEED"] = "false"
os.environ.setdefault("CANARY_DEFAULT_BUILDING_ID", "bld_007")  # hardware tests land here
os.environ.setdefault("CANARY_DEFAULT_ZONE_ID", "zone_hallway")
os.environ["CANARY_JWT_SECRET"] = "test-secret"
os.environ["CANARY_CARE_KEY"] = "dGVzdC1vbmx5LWNhcmUta2V5LTMyLWJ5dGVzLWxvbmc="  # Fernet test key

import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402

from app import demo_bridge  # noqa: E402
from app.config import settings  # noqa: E402
from app.db import Base, SessionLocal, engine, init_db  # noqa: E402
from app.main import app  # noqa: E402
from app.seed import seed  # noqa: E402

# the database file plus its WAL side files (SQLite runs in WAL mode)
_DB_FILES = [pathlib.Path(f"./test_canary.db{suffix}") for suffix in ("", "-wal", "-shm")]


def _remove_db_files() -> None:
    for path in _DB_FILES:
        path.unlink(missing_ok=True)


async def _drop_tables() -> None:
    """Postgres has no file to delete: drop every table, init_db then creates them afresh."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest_asyncio.fixture
async def client() -> AsyncClient:
    if settings.is_postgres:
        await _drop_tables()
    else:
        _remove_db_files()
    await init_db()
    async with SessionLocal() as session:
        await seed(session)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c

    await demo_bridge.drain()
    await engine.dispose()
    _remove_db_files()


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
