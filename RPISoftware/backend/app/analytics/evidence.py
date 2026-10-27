"""Structured fusion evidence and the observed sequence of an incident (F3b), for staff.

Both are read-only. `evidence_items` labels what F1 sensor trust, F2 motion and F4 room normals
say about the incident's rooms; it never feeds the fusion score or classification, so no item here
can make a hazard look benign. Motion is always weak context: a still room may hold people.

`evidence_timeline` replays stored rows only (readings, triangulation snapshots, motion
observations). It never recomputes triangulation, which would write a snapshot.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from statistics import median

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics import motion as mo
from app.analytics.zone_normal import building_normal
from app.detection.thresholds import thresholds_for
from app.enums import HAZARD_SENSOR_TYPES, SensorType
from app.models import Device, Incident, MotionObservation, SensorReading, TriangulationSnapshot

SUPPORTING, CONTRADICTING, CONTEXT, MISSING = "supporting", "contradicting", "context", "missing"
WEAK, NORMAL = "weak", "normal"

TIMELINE_LOOKBACK_S = 600  # sensors that crossed shortly before the incident row was opened
TIMELINE_READINGS_MAX = 5000
TIMELINE_ROWS_MAX = 500  # estimates and motion observations each
GAP_MIN_S = 60.0
GAP_FACTOR = 3.0  # a silence over 3x the device's usual interval is a gap
_HAZARDS = {t.value for t in HAZARD_SENSOR_TYPES}


def incident_zones(incident: Incident) -> set[str]:
    zones = set(incident.affected_zone_ids or [])
    if incident.primary_zone_id:
        zones.add(incident.primary_zone_id)
    return zones


def _item(source: str, zone_id: str | None, subject: str, status: str, role: str, strength: str, reason: str) -> dict:
    return {"source": source, "zone_id": zone_id, "subject": subject, "status": status,
            "role": role, "strength": strength, "reason": reason}


async def evidence_items(session: AsyncSession, incident: Incident, trust: list[dict],
                         now: datetime | None = None) -> list[dict]:
    """Labelled evidence for the incident's rooms from F1 trust, F2 motion and F4 room normals."""
    now = now or datetime.now(timezone.utc)
    zones = incident_zones(incident)
    if not zones:
        return []
    out: list[dict] = []

    device_zone = dict((await session.execute(
        select(Device.id, Device.zone_id).where(Device.building_id == incident.building_id, Device.zone_id.in_(zones))
    )).all())
    for node in trust:
        for ch in node["channels"]:
            zone = device_zone.get(ch["device_id"])
            if zone is None:
                continue
            if ch["state"] == "ok":
                role, strength = CONTEXT, NORMAL
            elif ch["state"] == "suspect":
                role, strength = CONTEXT, WEAK  # its readings count for less; never a reason to stand down
            else:
                role, strength = MISSING, WEAK
            out.append(_item("sensor_trust", zone, ch["device_id"], ch["state"], role, strength, ch["reason"]))

    zone_motion, _ = await mo.building_motion(session, incident.building_id, now)
    for zm in zone_motion:
        if zm.zone_id not in zones:
            continue
        role = CONTEXT if zm.state in {mo.MOTION, mo.NO_RECENT} else MISSING
        out.append(_item("motion", zm.zone_id, zm.zone_id, zm.state, role, WEAK, zm.state))

    for zn in await building_normal(session, incident.building_id, now):
        if zn.zone_id not in zones:
            continue
        for m in zn.metrics:
            hazard_metric = m.sensor_type == incident.hazard_type
            if m.status == "unusual_high":
                role, strength = SUPPORTING, NORMAL if hazard_metric else WEAK
            elif m.status == "usual" and hazard_metric:
                role, strength = CONTRADICTING, WEAK
            elif m.status in {"learning", "no_recent_data"}:
                role, strength = MISSING, WEAK
            else:
                role, strength = CONTEXT, WEAK
            out.append(_item("zone_normal", zn.zone_id, m.sensor_type, m.status, role, strength, m.status))
    return out


def _gaps(times: list[datetime]) -> list[dict]:
    deltas = [(b - a).total_seconds() for a, b in zip(times, times[1:])]
    positive = [d for d in deltas if d > 0]
    if not positive:
        return []
    limit = max(GAP_MIN_S, GAP_FACTOR * median(positive))
    return [{"start": a, "end": b, "seconds": d} for a, b, d in zip(times, times[1:], deltas) if d > limit]


def _over(row: SensorReading) -> bool:
    if row.edge_state == "alarm":
        return True
    th = thresholds_for(SensorType(row.sensor_type))
    return th is not None and row.value >= th.detection


async def evidence_timeline(session: AsyncSession, incident: Incident, now: datetime | None = None) -> dict:
    """What arrived when, from stored rows: per-device first arrival and data gaps, with the stored
    source estimates and motion observations kept as their own lists."""
    now = now or datetime.now(timezone.utc)
    start = incident.opened_ts - timedelta(seconds=TIMELINE_LOOKBACK_S)
    end = incident.resolved_ts or now
    zones = incident_zones(incident)

    q = select(SensorReading).where(
        SensorReading.building_id == incident.building_id,
        SensorReading.sensor_type.in_(_HAZARDS),
        SensorReading.ts >= start,
        SensorReading.ts <= end,
    )
    if zones:
        q = q.where(SensorReading.zone_id.in_(zones))
    rows = list((await session.scalars(
        q.order_by(SensorReading.ts, SensorReading.id).limit(TIMELINE_READINGS_MAX + 1)
    )).all())
    truncated = len(rows) > TIMELINE_READINGS_MAX
    rows = rows[:TIMELINE_READINGS_MAX]

    by_device: dict[str, list[SensorReading]] = {}
    for row in rows:
        by_device.setdefault(row.device_id, []).append(row)
    devices = []
    for device_id, history in by_device.items():
        first_over = next((r for r in history if _over(r)), None)
        out_of_order = sum(
            1 for a, b in zip(history, history[1:]) if b.epoch == a.epoch and b.seq < a.seq
        )
        devices.append({
            "device_id": device_id,
            "zone_id": history[0].zone_id,
            "sensor_type": history[0].sensor_type,
            "first_seen_ts": history[0].ts,
            "first_over_ts": first_over.ts if first_over else None,
            "first_over_value": first_over.value if first_over else None,
            "peak": max(r.value for r in history),
            "sample_count": len(history),
            "out_of_order": out_of_order,
            "gaps": _gaps([r.ts for r in history]),
        })
    arrivals = sorted((d for d in devices if d["first_over_ts"] is not None),
                      key=lambda d: (d["first_over_ts"], d["device_id"]))
    for rank, d in enumerate(arrivals, 1):
        d["order"] = rank
    for d in devices:
        d.setdefault("order", None)
    devices.sort(key=lambda d: (d["order"] is None, d["order"] or 0, d["first_seen_ts"], d["device_id"]))

    snaps = (await session.scalars(
        select(TriangulationSnapshot).where(TriangulationSnapshot.incident_id == incident.id)
        .order_by(TriangulationSnapshot.ts, TriangulationSnapshot.id).limit(TIMELINE_ROWS_MAX)
    )).all()
    motion = []
    if zones:
        motion = (await session.scalars(
            select(MotionObservation).where(
                MotionObservation.building_id == incident.building_id, MotionObservation.zone_id.in_(zones),
                MotionObservation.ts >= start, MotionObservation.ts <= end)
            .order_by(MotionObservation.ts, MotionObservation.id).limit(TIMELINE_ROWS_MAX)
        )).all()
    return {
        "incident_id": incident.id,
        "window_start": start,
        "window_end": end,
        "truncated": truncated,
        "devices": devices,
        "estimates": [
            {"ts": s.ts, "source_zone_id": s.source_zone_id, "confidence": s.confidence,
             "method": s.method, "n_contributors": s.n_contributors}
            for s in snaps
        ],
        "motion": [
            {"ts": m.ts, "zone_id": m.zone_id, "device_id": m.device_id, "state": m.state, "score": m.score}
            for m in motion
        ],
    }
