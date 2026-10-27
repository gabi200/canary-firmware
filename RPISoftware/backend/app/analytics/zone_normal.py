"""Per-room learned normal: the periodic job that freezes references (app.analytics.baseline) and
the read side that compares each room's latest readings with them.

The job runs under the processing lease (main._Workloads), hourly. A (zone, metric) is rebuilt when
it has no reference, is still learning, is older than REFRESH_DAYS, or holds only seed data. Seed
data is only replaced by a live reference that has enough samples. Each rebuild reads one bounded
window (at most MAX_REFERENCE_ROWS rows). The request path reads only the last RECENT of readings.
Both go through ix_sensor_readings_device_ts (the room's device ids and a time range).
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone, tzinfo
from zoneinfo import ZoneInfo

from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics import baseline as bl
from app.db import SessionLocal
from app.models import Building, Device, Incident, SensorReading, Zone, ZoneBaseline

log = logging.getLogger("canary.baseline")

REFRESH_DAYS = 7
MAX_REFERENCE_ROWS = 60_000  # 14 days at one reading / 20 s
RECENT = timedelta(minutes=10)
JOB_INTERVAL_S = 3600.0
JOB_FIRST_DELAY_S = 60.0  # let start-up and the MQTT backlog go first


def building_tz(building: Building | None) -> tzinfo:
    try:
        return ZoneInfo(building.timezone) if building and building.timezone else timezone.utc
    except (KeyError, ValueError):
        return timezone.utc


async def _incident_spans(session: AsyncSession, building_id: str, start: datetime, end: datetime):
    rows = await session.execute(
        select(Incident.opened_ts, Incident.resolved_ts).where(
            Incident.building_id == building_id, Incident.opened_ts <= end,
            or_(Incident.resolved_ts.is_(None), Incident.resolved_ts >= start - bl.INCIDENT_PAD_AFTER),
        )
    )
    return [(o, r) for o, r in rows]


def _due(rows: list[ZoneBaseline], now: datetime) -> bool:
    if not rows:
        return True
    flat = next((r for r in rows if r.hour == bl.ALL_HOURS), None)
    return (flat is None or flat.median is None or any(r.source != "live" for r in rows)
            or now - flat.computed_ts > timedelta(days=REFRESH_DAYS))


async def refresh_pair(session: AsyncSession, building_id: str, zone_id: str, metric: str, tz: tzinfo,
                       now: datetime) -> bool:
    """Rebuild one (zone, metric) reference when due; True when rows were written."""
    rows = list((await session.scalars(select(ZoneBaseline).where(
        ZoneBaseline.zone_id == zone_id, ZoneBaseline.sensor_type == metric))).all())
    if not _due(rows, now):
        return False
    start, end = bl.reference_window(now)
    device_ids = (await session.scalars(select(Device.id).where(
        Device.zone_id == zone_id, Device.sensor_type == metric))).all()
    raw = await session.execute(
        select(SensorReading.ts, SensorReading.value, SensorReading.edge_state).where(
            SensorReading.device_id.in_(device_ids), SensorReading.sensor_type == metric,
            SensorReading.zone_id == zone_id, SensorReading.ts >= start, SensorReading.ts < end,
        ).order_by(SensorReading.ts.desc()).limit(MAX_REFERENCE_ROWS)
    )
    samples = [bl.Sample(ts=ts, value=v, edge_state=e) for ts, v, e in raw]
    excluded = bl.incident_windows(await _incident_spans(session, building_id, start, end), now)
    # CPU-bound (~0.2 s per 60k samples on a laptop, more on a Pi): off the event loop, so ingestion keeps going
    refs = await asyncio.to_thread(bl.build_references, samples, excluded, tz)
    learning = refs[0].median is None
    if learning and any(r.source != "live" for r in rows):
        return False  # keep the labelled seed until live data is enough
    await session.execute(delete(ZoneBaseline).where(
        ZoneBaseline.zone_id == zone_id, ZoneBaseline.sensor_type == metric))
    session.add_all(ZoneBaseline(
        building_id=building_id, zone_id=zone_id, sensor_type=metric, hour=r.hour, median=r.median, mad=r.mad,
        n=r.n, ref_start=start, ref_end=end, source="live", computed_ts=now) for r in refs)
    await session.commit()
    return True


async def refresh_all(now: datetime | None = None) -> int:
    """Rebuild every due (zone, metric) that has a device; returns how many were written."""
    now = now or datetime.now(timezone.utc)
    async with SessionLocal() as session:
        pairs = (await session.execute(
            select(Device.building_id, Device.zone_id, Device.sensor_type)
            .where(Device.sensor_type.in_(bl.METRICS)).distinct()
        )).all()
        buildings = {b.id: b for b in (await session.scalars(select(Building))).all()}
    written = 0
    for building_id, zone_id, metric in pairs:
        async with SessionLocal() as session:  # one short transaction per pair
            written += await refresh_pair(session, building_id, zone_id, metric,
                                          building_tz(buildings.get(building_id)), now)
        await asyncio.sleep(0)  # let ingestion in between
    return written


async def run_baselines(stop: asyncio.Event) -> None:
    delay = JOB_FIRST_DELAY_S
    while not stop.is_set():
        try:
            await asyncio.wait_for(stop.wait(), timeout=delay)
            return
        except asyncio.TimeoutError:
            pass
        delay = JOB_INTERVAL_S
        try:
            written = await refresh_all()
            if written:
                log.info("zone baselines rebuilt: %d", written)
        except Exception:  # noqa: BLE001 - retried next hour
            log.exception("zone baseline refresh failed")


@dataclass
class MetricNormal:
    sensor_type: str
    status: str  # usual | unusual_high | unusual_low | learning | no_recent_data
    score: float | None
    value: float | None
    median: float | None
    mad: float | None
    n: int
    hour: int | None  # the bucket compared with; -1 all hours; None: no reference
    source: str | None  # live | seed
    ref_start: datetime | None
    ref_end: datetime | None


@dataclass
class ZoneNormal:
    zone_id: str
    label: str
    metrics: list[MetricNormal]


async def building_normal(session: AsyncSession, building_id: str, now: datetime | None = None) -> list[ZoneNormal]:
    """Every zone with a continuous hazard sensor (or a reference) and how its latest reading
    compares with its own frozen normal."""
    now = now or datetime.now(timezone.utc)
    tz = building_tz(await session.get(Building, building_id))
    zones = (await session.scalars(select(Zone).where(Zone.building_id == building_id).order_by(Zone.id))).all()
    refs = (await session.scalars(select(ZoneBaseline).where(ZoneBaseline.building_id == building_id))).all()
    devices = (await session.execute(
        select(Device.id, Device.zone_id, Device.sensor_type).where(
            Device.building_id == building_id, Device.sensor_type.in_(bl.METRICS))
    )).all()
    pairs = {(z, m) for _, z, m in devices} | {(r.zone_id, r.sensor_type) for r in refs}
    recent = await session.execute(
        select(SensorReading.zone_id, SensorReading.sensor_type, SensorReading.device_id, SensorReading.value)
        .where(SensorReading.device_id.in_([d for d, _, _ in devices]), SensorReading.ts >= now - RECENT)
        .order_by(SensorReading.ts)
    )
    latest: dict[tuple[str, str, str], float] = {}
    for zone_id, metric, device_id, value in recent:
        latest[(zone_id, metric, device_id)] = value  # ordered by ts: the last one wins
    hour = now.astimezone(tz).hour
    out = []
    for zone in zones:
        metrics = []
        for metric in bl.METRICS:
            if (zone.id, metric) not in pairs:
                continue
            rows = [r for r in refs if r.zone_id == zone.id and r.sensor_type == metric]
            values = [v for (z, m, _), v in latest.items() if z == zone.id and m == metric]
            value = max(values) if values else None  # the worst device in the room
            chosen = bl.pick_reference([bl.Reference(r.hour, r.median, r.mad, r.n) for r in rows], hour)
            row = next((r for r in rows if chosen and r.hour == chosen.hour), None)
            a = bl.assess(metric, value, chosen)
            metrics.append(MetricNormal(
                sensor_type=metric, status=a.status, score=a.score, value=value,
                median=chosen.median if chosen else None, mad=chosen.mad if chosen else None,
                n=chosen.n if chosen else 0, hour=chosen.hour if chosen else None,
                source=row.source if row else None, ref_start=row.ref_start if row else None,
                ref_end=row.ref_end if row else None))
        if metrics:
            out.append(ZoneNormal(zone_id=zone.id, label=zone.label, metrics=metrics))
    return out
