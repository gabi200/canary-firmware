"""Async SQLAlchemy engine, session factory, and schema bootstrap.

Works against PostgreSQL/TimescaleDB (prod) and SQLite (dev/tests). TimescaleDB
hypertables are created only on a real Postgres dialect; on SQLite the same tables
are plain tables so the rest of the app is storage-agnostic.
"""

from __future__ import annotations

from collections.abc import AsyncIterator

from sqlalchemy import text
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


engine = create_async_engine(settings.database_url, future=True, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session


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
