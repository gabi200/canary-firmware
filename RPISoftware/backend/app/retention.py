"""Hourly retention: prune time-series rows older than `settings.retention_days`.

On the Pi the database lives on an SD card; raw status snapshots (one per status
document), canonical readings, occupancy estimates and signature assessments would
otherwise grow without bound. Incidents, events, check-ins and the audit log are never pruned.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from app.config import settings
from app.db import SessionLocal
from app.models import NodeStatus, OccupancyEstimate, SensorReading, SignatureAssessmentRow, TriangulationSnapshot

log = logging.getLogger("canary.retention")

PRUNE_INTERVAL_S = 3600
# Rows per transaction: keeps each write lock short so live ingestion never waits long.
PRUNE_BATCH = 2000
_PRUNED = (NodeStatus, SensorReading, OccupancyEstimate, SignatureAssessmentRow, TriangulationSnapshot)


async def prune_old_rows(now: datetime | None = None) -> dict[str, int]:
    """Delete rows older than the retention window; returns rows deleted per table."""
    if settings.retention_days <= 0:
        return {}
    cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=settings.retention_days)
    deleted: dict[str, int] = {}
    for model in _PRUNED:
        total = 0
        while True:
            async with SessionLocal() as session:
                ids = (await session.scalars(select(model.id).where(model.ts < cutoff).limit(PRUNE_BATCH))).all()
                if ids:
                    await session.execute(delete(model).where(model.id.in_(ids)))
                    await session.commit()
            total += len(ids)
            if len(ids) < PRUNE_BATCH:
                break
            await asyncio.sleep(0)  # let the MQTT consumer in between batches
        deleted[model.__tablename__] = total
    return deleted


async def run_retention(stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            deleted = await prune_old_rows()
            if any(deleted.values()):
                log.info("retention pruned %s", deleted)
        except Exception:  # noqa: BLE001 - a failed prune is retried next hour
            log.exception("retention prune failed")
        try:
            await asyncio.wait_for(stop.wait(), timeout=PRUNE_INTERVAL_S)
        except asyncio.TimeoutError:
            pass
