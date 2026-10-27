"""Seed per-room "normal" references from labelled synthetic data, for a demo hub without two
weeks of history: `python -m tools.baseline_seed [--building bld_007]`.

Writes zone_baselines rows with source="seed" (the dashboard labels them "simulated seed data")
for every (zone, metric) that has a device, built with the same code as live references from a
deterministic 14-day synthetic series: a steady level with noise, and for kitchens an evening
cooking bump in particulates, so the hour buckets differ. Live references are never overwritten,
and the hourly job replaces seed rows as soon as real readings are enough. Nothing goes into
sensor_readings.
"""

from __future__ import annotations

import argparse
import asyncio
import random
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from app.analytics import baseline as bl
from app.analytics.zone_normal import building_tz
from app.db import SessionLocal, init_db
from app.models import Building, Device, Zone, ZoneBaseline

STEP = timedelta(minutes=5)
LEVEL = {"co": (2.0, 0.6), "combustible_gas": (320.0, 15.0), "particulate": (8.0, 2.0)}  # (mean, noise)


def synthetic(metric: str, kitchen: bool, start: datetime, end: datetime, tz, rng: random.Random) -> list[bl.Sample]:
    mean, noise = LEVEL[metric]
    out, ts = [], start
    while ts < end:
        value = mean + rng.gauss(0, noise)
        if kitchen and metric == "particulate" and 18 <= ts.astimezone(tz).hour < 21:
            value += 15.0  # dinner
        out.append(bl.Sample(ts=ts, value=max(0.0, value)))
        ts += STEP
    return out


async def seed_baselines(building_id: str, now: datetime | None = None, seed: int = 7) -> int:
    now = now or datetime.now(timezone.utc)
    start, end = bl.reference_window(now)
    rng = random.Random(seed)
    written = 0
    async with SessionLocal() as session:
        tz = building_tz(await session.get(Building, building_id))
        kinds = dict((await session.execute(select(Zone.id, Zone.kind).where(Zone.building_id == building_id))).all())
        pairs = sorted(set((await session.execute(
            select(Device.zone_id, Device.sensor_type).where(
                Device.building_id == building_id, Device.sensor_type.in_(bl.METRICS))
        )).all()))
        for zone_id, metric in pairs:
            existing = (await session.scalars(select(ZoneBaseline.source).where(
                ZoneBaseline.zone_id == zone_id, ZoneBaseline.sensor_type == metric))).all()
            if "live" in existing:
                continue  # real data wins
            refs = bl.build_references(synthetic(metric, kinds.get(zone_id) == "kitchen", start, end, tz, rng), [], tz)
            await session.execute(delete(ZoneBaseline).where(
                ZoneBaseline.zone_id == zone_id, ZoneBaseline.sensor_type == metric))
            session.add_all(ZoneBaseline(
                building_id=building_id, zone_id=zone_id, sensor_type=metric, hour=r.hour, median=r.median,
                mad=r.mad, n=r.n, ref_start=start, ref_end=end, source="seed", computed_ts=now) for r in refs)
            written += 1
        await session.commit()
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--building", default="bld_007")
    args = parser.parse_args()

    async def run() -> None:
        await init_db()
        print(f"seeded {await seed_baselines(args.building)} (zone, metric) references for {args.building}")

    asyncio.run(run())


if __name__ == "__main__":
    main()
