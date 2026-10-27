"""Per-room learned normal: frozen median/MAD references, incident exclusion, hour buckets, the
hourly job, the labelled seed, the endpoint, and that none of it touches the alarm path."""

from __future__ import annotations

import random
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.analytics import baseline as bl
from app.analytics.zone_normal import refresh_all
from app.db import SessionLocal
from app.models import Incident, SensorReading, ZoneBaseline
from tests.conftest import auth_token, telemetry
from tools.baseline_seed import seed_baselines

UTC = timezone.utc
NOW = datetime(2026, 10, 27, 12, 0, tzinfo=UTC)


def _series(start: datetime, hours: float, value=2.0, step_min=5, jitter=0.3, seed=1) -> list[bl.Sample]:
    rng = random.Random(seed)
    n = int(hours * 60 / step_min)
    return [bl.Sample(ts=start + timedelta(minutes=i * step_min), value=value + rng.uniform(-jitter, jitter))
            for i in range(n)]


# --------------------------------------------------------------------------- pure

def test_learning_until_enough_samples_and_span():
    start, _ = bl.reference_window(NOW)
    assert bl.build_references(_series(start, 10), [], UTC)[0].median is None  # 120 samples
    short = [bl.Sample(ts=start + timedelta(seconds=i), value=2.0) for i in range(500)]  # 8 minutes
    refs = bl.build_references(short, [], UTC)
    assert refs[0].median is None and refs[0].n == 500
    assert bl.assess("co", 2.0, refs[0]).status == bl.LEARNING


def test_incident_windows_and_flagged_samples_are_excluded():
    start, _ = bl.reference_window(NOW)
    samples = _series(start, 72)
    spike_at = start + timedelta(hours=30)
    smoke = [bl.Sample(ts=spike_at + timedelta(minutes=i), value=400.0) for i in range(120)]
    flagged = [bl.Sample(ts=start + timedelta(hours=50, minutes=i), value=300.0, edge_state="warn") for i in range(120)]
    windows = bl.incident_windows([(spike_at, spike_at + timedelta(hours=2))], NOW)
    ref = bl.build_references(samples + smoke + flagged, windows, UTC)[0]
    assert ref.n == len(samples) - sum(1 for s in samples if windows[0][0] <= s.ts <= windows[0][1])
    assert 1.7 < ref.median < 2.3


def test_open_incident_excluded_up_to_now():
    (start, end), = bl.incident_windows([(NOW - timedelta(hours=1), None)], NOW)
    assert start == NOW - timedelta(hours=1) - bl.INCIDENT_PAD_BEFORE and end == NOW + bl.INCIDENT_PAD_AFTER


def test_hour_buckets_only_with_enough_days():
    start, _ = bl.reference_window(NOW)
    assert {r.hour for r in bl.build_references(_series(start, 3 * 24), [], UTC)} == {bl.ALL_HOURS}
    week = _series(start, 10 * 24)
    evening = [bl.Sample(s.ts, s.value + 20) if s.ts.hour == 19 else s for s in week]
    refs = bl.build_references(evening, [], UTC)
    by_hour = {r.hour: r for r in refs}
    assert len(by_hour) == 25
    assert by_hour[19].median > 20 and by_hour[3].median < 3
    assert bl.pick_reference(refs, 19).hour == 19
    assert bl.pick_reference([refs[0]], 19).hour == bl.ALL_HOURS


def test_order_and_duplicates_do_not_change_the_reference():
    start, _ = bl.reference_window(NOW)
    samples = _series(start, 48)
    shuffled = samples[:] + samples[:50]  # redelivered rows
    random.Random(3).shuffle(shuffled)
    a, b = bl.build_references(samples, [], UTC)[0], bl.build_references(shuffled, [], UTC)[0]
    assert abs(a.median - b.median) < 0.05


def test_assess_scores_and_spread_floor():
    flat = bl.Reference(hour=-1, median=2.0, mad=0.0, n=500)  # a perfectly quiet room
    assert bl.assess("co", 2.4, flat).status == bl.USUAL  # floor: 1 ppm, not "unusual" on a tick
    high = bl.assess("co", 9.0, flat)
    assert high.status == bl.UNUSUAL_HIGH and high.score == 7.0  # a deviation, not a probability
    assert bl.assess("co", -5.0, flat).status == bl.UNUSUAL_LOW
    assert bl.assess("co", None, flat).status == bl.NO_RECENT
    assert bl.assess("co", 2.0, None).status == bl.LEARNING


# --------------------------------------------------------------------------- job + API

_seq = iter(range(10**9))


async def _add_readings(device: str, zone: str, sensor: str, values: list[tuple[datetime, float]], edge="normal"):
    async with SessionLocal() as s:
        for ts, v in values:
            s.add(SensorReading(device_id=device, building_id="bld_007", floor_id="flr_03", unit_id="unit_0312",
                                zone_id=zone, sensor_type=sensor, value=v, edge_state=edge, epoch=9,
                                seq=next(_seq), ts=ts))
        await s.commit()


async def _history(now: datetime, days=3, value=2.0):
    start, _ = bl.reference_window(now)
    rng = random.Random(5)
    await _add_readings("dev_co_bedroom", "zone_bedroom", "co", [
        (start + timedelta(minutes=10 * i), value + rng.uniform(-0.3, 0.3)) for i in range(days * 144)])


async def _normal(client, user="mihai") -> dict:
    token = await auth_token(client, user)
    resp = await client.get("/api/v1/buildings/bld_007/zone-normal", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    return {(z["zone_id"], m["sensor_type"]): m for z in resp.json()["zones"] for m in z["metrics"]}


async def test_job_builds_frozen_reference_and_endpoint_compares(client):
    now = datetime.now(UTC)
    await _history(now)
    assert await refresh_all(now) >= 1
    async with SessionLocal() as s:
        first = (await s.scalars(select(ZoneBaseline).where(ZoneBaseline.zone_id == "zone_bedroom"))).one()
    await refresh_all(now + timedelta(hours=1))  # only rooms still learning are rebuilt
    async with SessionLocal() as s:
        again = (await s.scalars(select(ZoneBaseline).where(ZoneBaseline.zone_id == "zone_bedroom"))).one()
    assert (again.id, again.computed_ts) == (first.id, first.computed_ts)  # frozen

    await _add_readings("dev_co_bedroom", "zone_bedroom", "co", [(now - timedelta(minutes=1), 2.2)])
    m = (await _normal(client))[("zone_bedroom", "co")]
    assert m["status"] == "usual" and m["source"] == "live" and m["hour"] == -1 and m["n"] == 3 * 144

    await _add_readings("dev_co_bedroom", "zone_bedroom", "co", [(now - timedelta(seconds=10), 12.0)])
    m = (await _normal(client))[("zone_bedroom", "co")]
    assert m["status"] == "unusual_high" and m["value"] == 12.0 and m["score"] > 3


async def test_recent_drift_is_not_absorbed(client):
    now = datetime.now(UTC)
    await _history(now)
    await refresh_all(now)
    # the last day (outside the reference window) creeps up; the reference stays where it was
    await _add_readings("dev_co_bedroom", "zone_bedroom", "co",
                        [(now - timedelta(hours=20) + timedelta(minutes=10 * i), 2.0 + i * 0.05) for i in range(120)])
    await refresh_all(now + timedelta(hours=1))
    async with SessionLocal() as s:
        ref = (await s.scalars(select(ZoneBaseline).where(ZoneBaseline.zone_id == "zone_bedroom",
                                                          ZoneBaseline.sensor_type == "co"))).one()
    assert 1.8 < ref.median < 2.2
    await _add_readings("dev_co_bedroom", "zone_bedroom", "co", [(now - timedelta(seconds=5), 7.9)])
    assert (await _normal(client))[("zone_bedroom", "co")]["status"] == "unusual_high"


async def test_incident_readings_stay_out_of_the_reference(client):
    now = datetime.now(UTC)
    await _history(now)
    start, _ = bl.reference_window(now)
    hot = start + timedelta(days=1)
    async with SessionLocal() as s:
        s.add(Incident(building_id="bld_007", hazard_type="co", state="resolution", opened_ts=hot,
                       resolved_ts=hot + timedelta(hours=6)))
        await s.commit()
    await _add_readings("dev_co_bedroom", "zone_bedroom", "co",
                        [(hot + timedelta(minutes=i), 150.0) for i in range(300)])
    await refresh_all(now)
    async with SessionLocal() as s:
        ref = (await s.scalars(select(ZoneBaseline).where(ZoneBaseline.zone_id == "zone_bedroom"))).one()
    assert 1.8 < ref.median < 2.2


async def test_learning_state_without_history(client):
    await refresh_all(datetime.now(UTC))
    m = (await _normal(client))[("zone_kitchen", "combustible_gas")]
    assert m["status"] == "learning" and m["median"] is None


async def test_seed_is_labelled_and_replaced_only_by_enough_live_data(client):
    now = datetime.now(UTC)
    assert await seed_baselines("bld_007", now) >= 4
    normal = await _normal(client)
    kitchen_pm = [m for (z, metric), m in normal.items() if z == "zone_kitchen"]
    assert kitchen_pm and all(m["source"] == "seed" for m in kitchen_pm)
    await refresh_all(now)  # no readings yet: the seed stays
    assert (await _normal(client))[("zone_bedroom", "co")]["source"] == "seed"
    await _history(now)
    await refresh_all(now)
    assert (await _normal(client))[("zone_bedroom", "co")]["source"] == "live"
    assert await seed_baselines("bld_007", now) >= 1  # other pairs; never over the live one
    assert (await _normal(client))[("zone_bedroom", "co")]["source"] == "live"


async def test_zone_normal_roles(client):
    token = await auth_token(client, "ana")
    resp = await client.get("/api/v1/buildings/bld_007/zone-normal", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 403
    for user in ("dispecer", "tehnician", "admin"):
        await _normal(client, user)
    token = await auth_token(client, "mihai")
    assert (await client.get("/api/v1/buildings/nope/zone-normal",
                             headers={"Authorization": f"Bearer {token}"})).status_code == 404


async def test_alarm_regression_usual_room_still_evacuates(client):
    """A reference never suppresses: even one that calls 6000 'usual' leaves the critical path alone."""
    now = datetime.now(UTC)
    async with SessionLocal() as s:
        start, end = bl.reference_window(now)
        s.add(ZoneBaseline(building_id="bld_007", zone_id="zone_kitchen", sensor_type="combustible_gas", hour=-1,
                           median=6000.0, mad=500.0, n=999, ref_start=start, ref_end=end, source="seed"))
        await s.commit()
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312"))
    assert resp.json()["incident_state"] == "evacuation"
    assert (await _normal(client))[("zone_kitchen", "combustible_gas")]["status"] == "usual"
