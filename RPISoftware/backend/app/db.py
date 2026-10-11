"""Async SQLAlchemy engine, session factory, and schema bootstrap.

Works against PostgreSQL/TimescaleDB (prod) and SQLite (dev/tests). TimescaleDB
hypertables are created only on a real Postgres dialect; on SQLite the same tables
are plain tables so the rest of the app is storage-agnostic.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import (
    AsyncAttrs,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

from app.config import settings


class Base(AsyncAttrs, DeclarativeBase):
    pass


# pre-ping guards against dropped server connections; a local SQLite file has none, and on the
# Pi every ping is one more thread round trip per session.
engine = create_async_engine(settings.database_url, future=True, pool_pre_ping=not settings.database_url.startswith(
    "sqlite"))
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)

if engine.dialect.name == "sqlite":

    @event.listens_for(engine.sync_engine, "connect")
    def _sqlite_pragmas(dbapi_connection, _record) -> None:
        # WAL lets dashboard reads run alongside the MQTT writer (the Pi runs SQLite);
        # busy_timeout makes a writer wait for the lock instead of failing "database is locked";
        # synchronous=NORMAL (safe with WAL) skips an fsync per commit, sparing the SD card —
        # a power cut can lose the last few commits, never corrupt the database.
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=5000")
        cursor.execute("PRAGMA synchronous=NORMAL")
        cursor.close()


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session


# Indexes added after a table first shipped: `create_all` never touches existing tables, so these
# are created idempotently on every start (same definitions as in app.models).
_LATE_INDEXES = (
    "CREATE INDEX IF NOT EXISTS ix_sensor_readings_device_ts ON sensor_readings (device_id, ts)",
)

# TimescaleDB hypertables (time-series entities). (table, time_column)
_HYPERTABLES: list[tuple[str, str]] = [
    ("sensor_readings", "ts"),
    ("device_health", "ts"),
    ("occupancy_estimates", "ts"),
]


async def init_db() -> None:
    """Create all tables; convert time-series tables to hypertables on Postgres/Timescale."""
    # Import models so they register on Base.metadata before create_all.
    from app import models  # noqa: F401

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        for statement in _LATE_INDEXES:
            await conn.execute(text(statement))

        if settings.is_postgres:
            # TimescaleDB extension + hypertables (idempotent, best-effort).
            try:
                await conn.execute(text("CREATE EXTENSION IF NOT EXISTS timescaledb"))
                for table, time_col in _HYPERTABLES:
                    await conn.execute(
                        text(
                            "SELECT create_hypertable("
                            f"'{table}', '{time_col}', if_not_exists => TRUE, "
                            "migrate_data => TRUE)"
                        )
                    )
            except Exception:  # pragma: no cover - timescaledb may be absent
                # Plain Postgres without the extension still works; hypertables are an
                # optimization, not a correctness requirement.
                pass
