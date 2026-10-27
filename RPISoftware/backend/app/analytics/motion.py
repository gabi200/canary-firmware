"""Per-zone motion evidence from ESPectre boards (app.ingestion.espectre), for staff.

Reads only `motion_sensors` (one row per board), so a request costs one small query. Board states,
worst to best: `unavailable` (offline, silent for STALE_S, or no health/sensing state yet),
`calibrating` (not ready), `no_recent_motion`, `motion`. A zone shows its best board; a zone with
no board is `no_presence_sensor`. Motion is evidence of movement only: `no_recent_motion` never
means the room is empty, and nothing here is a person count.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import MotionSensor, Zone

STALE_S = 60.0  # a board's retained health can say online after its Wi-Fi dropped; silence wins
RECENT_S = 30.0  # motion stored within this is "motion detected"

MOTION, NO_RECENT, CALIBRATING, UNAVAILABLE, NO_SENSOR = (
    "motion", "no_recent_motion", "calibrating", "unavailable", "no_presence_sensor")
_RANK = {MOTION: 3, NO_RECENT: 2, CALIBRATING: 1, UNAVAILABLE: 0}


@dataclass
class SensorState:
    device_id: str
    zone_id: str | None
    state: str
    reason: str
    firmware: str
    last_seen_ts: datetime | None
    last_motion_ts: datetime | None


@dataclass
class ZoneMotion:
    zone_id: str
    label: str
    state: str
    last_motion_ts: datetime | None
    last_motion_age_s: float | None
    sensors: list[SensorState]


def _age(ts: datetime | None, now: datetime) -> float | None:
    return None if ts is None else max(0.0, (now - ts).total_seconds())


def sensor_state(sensor: MotionSensor, now: datetime) -> tuple[str, str]:
    """(state, reason) for one board."""
    seen = _age(sensor.last_seen_ts, now)
    if sensor.online is None:
        return UNAVAILABLE, "no health message yet"
    if not sensor.online:
        return UNAVAILABLE, "board reports offline"
    if seen is None or seen > STALE_S:
        return UNAVAILABLE, f"no message for over {STALE_S:.0f} s"
    if sensor.ready is None:
        return UNAVAILABLE, "no sensing state yet"
    if sensor.calibrating or not sensor.ready:
        return CALIBRATING, "calibrating" if sensor.calibrating else "detector not ready"
    motion_age = _age(sensor.last_motion_ts, now)
    if motion_age is not None and motion_age <= RECENT_S:
        return MOTION, "motion detected"
    return NO_RECENT, "no motion seen recently (not proof the room is empty)"


async def building_motion(session: AsyncSession, building_id: str,
                          now: datetime | None = None) -> tuple[list[ZoneMotion], list[SensorState]]:
    """Every zone of the building with its motion state, and the boards no zone is configured for."""
    now = now or datetime.now(timezone.utc)
    zones = (await session.scalars(select(Zone).where(Zone.building_id == building_id).order_by(Zone.id))).all()
    sensors = (await session.scalars(
        select(MotionSensor).where(or_(MotionSensor.building_id == building_id, MotionSensor.zone_id.is_(None)))
        .order_by(MotionSensor.device_id)
    )).all()
    states = []
    for s in sensors:
        state, reason = sensor_state(s, now)
        states.append(SensorState(device_id=s.device_id, zone_id=s.zone_id, state=state, reason=reason,
                                  firmware=s.firmware, last_seen_ts=s.last_seen_ts, last_motion_ts=s.last_motion_ts))
    out = []
    for zone in zones:
        mine = [s for s in states if s.zone_id == zone.id]
        last = max((s.last_motion_ts for s in mine if s.last_motion_ts), default=None)
        state = max((s.state for s in mine), key=_RANK.__getitem__, default=NO_SENSOR)
        out.append(ZoneMotion(zone_id=zone.id, label=zone.label, state=state, last_motion_ts=last,
                              last_motion_age_s=_age(last, now), sensors=mine))
    return out, [s for s in states if s.zone_id is None]
