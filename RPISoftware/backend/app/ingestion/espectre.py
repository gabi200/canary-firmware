"""ESPectre adapter: stock ESPectre Wi-Fi motion boards (deployed separately; docs/ESPECTRE.md).

Topics under CANARY_ESPECTRE_TOPIC_PREFIX (`espectre/v1/devices`), per ESPectre 3.0.0 docs/API.md:

- `<prefix>/<id>/motion` (not retained): `{"timestamp_ms", "state": "idle"|"motion", "score"}`
- `<prefix>/<id>/health` (retained, the Last Will says offline): `{"status", "online", ...}`
- `<prefix>/<id>/sensing` (retained): `ready`, `calibrating`, `threshold`
- `<prefix>/<id>/device` (retained): `firmware`
- anything else is ignored.

Motion is its own evidence stream, never a `SensorType`: `wifi_presence` readings feed
`OccupancyService.record_presence(persons_est=value)`, which would read a 0.7 score as 0.7 people.
Nothing here touches readings, incidents or occupancy. ESPectre's own doc: "idle means no
motion, not an empty room".

`timestamp_ms` is the board's monotonic clock. The board's boot time is estimated as receive time
minus that clock; within one boot an equal clock is a duplicate (QoS 1 redelivery) and a smaller
one arrived out of order: both are dropped. Every state change is stored, an unchanged state at
most every CANARY_ESPECTRE_STORE_INTERVAL_S, so a board evaluating several times a second costs a
write every few seconds. MQTT is a trust boundary: bad input is logged and dropped, never raised.
"""

from __future__ import annotations

import json
import logging
import math
import re
from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import select

from app.config import settings
from app.db import SessionLocal
from app.models import MotionObservation, MotionSensor, Zone

log = logging.getLogger("canary.espectre")

MAX_PAYLOAD_BYTES = 4 * 1024  # ESPectre documents are a few hundred bytes
BOOT_TOLERANCE_S = 30.0  # two boot estimates closer than this are the same boot
DUPLICATE_WINDOW_S = 60.0  # after a hub restart: a stored row this recent with the same clock is a repeat
_DEVICE_ID = re.compile(r"^[0-9a-f]{16}$")
_KINDS = ("motion", "health", "sensing", "device")


@dataclass
class _Last:
    boot_ts: float  # estimated board boot time (epoch s)
    source_ms: int
    state: str
    stored_ts: float  # when an observation was last stored (epoch s)


_last: dict[str, _Last] = {}
_unmapped_warned: set[str] = set()


def reset_state() -> None:
    """Forget per-board state (a new turn as processing node starts from the database)."""
    _last.clear()
    _unmapped_warned.clear()


def handles(topic: str) -> bool:
    return topic.startswith(settings.espectre_topic_prefix.rstrip("/") + "/")


def _parse(raw: bytes) -> dict | None:
    if len(raw) > MAX_PAYLOAD_BYTES:
        return None
    try:
        doc = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return doc if isinstance(doc, dict) else None


def _bool(value: object) -> bool | None:
    return value if isinstance(value, bool) else None


def _finite(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return float(value)


async def handle_espectre_message(topic: str, raw: bytes, *, retain: bool = False,
                                  received_ts: float | None = None) -> None:
    """Handle one ESPectre message; logs and drops bad input, never raises."""
    try:
        rest = topic[len(settings.espectre_topic_prefix.rstrip("/")) + 1:].split("/")
        if len(rest) != 2 or not _DEVICE_ID.match(rest[0]) or rest[1] not in _KINDS:
            return
        device_id, kind = rest
        doc = _parse(raw)
        if doc is None:
            log.warning("dropping malformed ESPectre message on %r", topic[:200])
            return
        received = received_ts if received_ts else datetime.now(timezone.utc).timestamp()
        if kind == "motion":
            if not retain:  # motion is never retained by the board; a retained one is stale
                await _motion(device_id, doc, received)
        else:
            await _state(device_id, kind, doc, received)
    except Exception:  # noqa: BLE001 - trust boundary: never crash the consumer
        log.exception("dropping ESPectre message on %r", topic[:200])


async def _sensor(session, device_id: str) -> MotionSensor:
    """The board's row, (re)placed in its configured zone."""
    sensor = await session.get(MotionSensor, device_id)
    if sensor is None:
        sensor = MotionSensor(device_id=device_id)
        session.add(sensor)
    zone_id = settings.espectre_zones.get(device_id)
    zone = await session.get(Zone, zone_id) if zone_id else None
    if zone is None and device_id not in _unmapped_warned:
        _unmapped_warned.add(device_id)
        log.warning("ESPectre board %s has no zone in CANARY_ESPECTRE_ZONES (or the zone %r does not exist):"
                    " its motion is not stored", device_id, zone_id)
    sensor.zone_id = zone.id if zone else None
    sensor.building_id = zone.building_id if zone else None
    return sensor


async def _state(device_id: str, kind: str, doc: dict, received: float) -> None:
    async with SessionLocal() as session:
        sensor = await _sensor(session, device_id)
        sensor.last_seen_ts = datetime.fromtimestamp(received, timezone.utc)
        if kind == "health":
            online = _bool(doc.get("online"))
            status = doc.get("status")
            sensor.online = online if online is not None else (status == "ok" if isinstance(status, str) else None)
        elif kind == "sensing":
            sensor.ready = _bool(doc.get("ready"))
            sensor.calibrating = _bool(doc.get("calibrating"))
            threshold = _finite(doc.get("threshold"))
            sensor.threshold = threshold if threshold is not None and 0.0 <= threshold <= 1.0 else None
        elif kind == "device":
            firmware = doc.get("firmware")
            sensor.firmware = firmware[:64] if isinstance(firmware, str) else ""
        await session.commit()


async def _repeat_after_restart(session, device_id: str, source_ms: int, received: float) -> bool:
    """No in-memory state (the hub restarted): whether the latest stored row is this same message."""
    row = (await session.execute(
        select(MotionObservation.source_ms, MotionObservation.ts).where(MotionObservation.device_id == device_id)
        .order_by(MotionObservation.ts.desc()).limit(1)
    )).first()
    return row is not None and row.source_ms == source_ms and received - row.ts.timestamp() < DUPLICATE_WINDOW_S


async def _motion(device_id: str, doc: dict, received: float) -> None:
    source_ms, state, score = doc.get("timestamp_ms"), doc.get("state"), _finite(doc.get("score"))
    if isinstance(source_ms, bool) or not isinstance(source_ms, int) or source_ms < 0 \
            or state not in ("idle", "motion") or score is None:
        log.warning("dropping ESPectre motion from %s: bad timestamp_ms, state or score", device_id)
        return
    boot = received - source_ms / 1000.0
    last = _last.get(device_id)
    if last is not None and abs(boot - last.boot_ts) < BOOT_TOLERANCE_S:
        if source_ms <= last.source_ms:
            log.debug("dropping %s motion from %s at %d ms (latest %d ms)",
                      "duplicate" if source_ms == last.source_ms else "out-of-order", device_id,
                      source_ms, last.source_ms)
            return
        boot = last.boot_ts  # keep one estimate per boot
    if last is not None and last.state == state and abs(boot - last.boot_ts) < BOOT_TOLERANCE_S \
            and received - last.stored_ts < settings.espectre_store_interval_s:
        last.source_ms = source_ms
        return
    async with SessionLocal() as session:
        if last is None and await _repeat_after_restart(session, device_id, source_ms, received):
            return
        sensor = await _sensor(session, device_id)
        now = datetime.fromtimestamp(received, timezone.utc)
        sensor.last_seen_ts = now
        if state == "motion":
            sensor.last_motion_ts = now
        if sensor.zone_id is not None:
            session.add(MotionObservation(
                device_id=device_id, zone_id=sensor.zone_id, building_id=sensor.building_id, score=score,
                state=state, source_ms=source_ms, ready=sensor.ready, ts=now,
            ))
        await session.commit()
    _last[device_id] = _Last(boot_ts=boot, source_ms=source_ms, state=state, stored_ts=received)


def subscriptions() -> list[str]:
    """Extra topic filters the consumer subscribes to: none when CANARY_MQTT_SUBSCRIBE already covers
    every topic (two overlapping filters could deliver a message twice)."""
    if settings.mqtt_subscribe == "#":
        return []
    return [f"{settings.espectre_topic_prefix.rstrip('/')}/+/{kind}" for kind in _KINDS]

