"""Hardware adapter: the real ESP32 firmware's MQTT -> canonical pipeline (docs/HARDWARE.md).

`<base>/status` documents from the air (ESP32-S3) and water (ESP32-C3) nodes become
canonical `canary.telemetry.v1` payloads and run through the same `ingest_telemetry`
path as the legacy topics, so detection, the incident state machine and
notifications are shared. Every accepted document is also stored raw (`node_status`)
for the dashboard's history. `<base>/availability` tracks online/offline.

MQTT is a trust boundary: anything on the broker can publish. Every field is
type-checked, a malformed or hostile message is logged and dropped, and nothing
here raises into the consumer loop.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time
from collections.abc import Iterable
from datetime import datetime, timezone

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.environment import finite_number
from app.analytics.nodes import broadcast_node, device_ids
from app.config import settings
from app.db import SessionLocal
from app.enums import NODE_CHANNELS, EdgeState, NodeKind, SensorType
from app.ingestion.pipeline import ingest_telemetry
from app.models import Device, Node, NodeStatus, Zone
from app.schemas import Location, ReadingThresholds, Signal, TelemetryPayload

log = logging.getLogger("canary.hardware")

MAX_PAYLOAD_BYTES = 16 * 1024  # firmware documents are < 2 KiB
MAX_DEPTH = 4  # firmware documents nest 2 levels; deeper ones are stored verbatim otherwise
MAX_BASE_LEN = 128  # firmware base topics are <= 64 chars
MAX_NODES = 500  # auto-registration cap: a rogue publisher cannot flood the database
MAX_PENDING_AVAILABILITY = 256
PRESENCE_REFRESH_S = 300.0  # presence readings on change, or at least every 5 min
_TEXT_MAX = 64

# air hazard channel -> (value key, units, warn key, danger key)
_AIR_HAZARDS = {
    "co": ("ppm", "ppm", "warn_ppm", "danger_ppm"),
    "gas": ("adc", "adc", "warn_adc", "danger_adc"),  # raw MQ5 ADC counts, not ppm
    "particulate": ("pm2_5", "ug/m3", "warn_pm2_5", "danger_pm2_5"),
}
# device channel grading -> edge state; warmup / fault produce no reading
_EDGE_BY_STATE = {"ok": EdgeState.normal, "warning": EdgeState.warn, "danger": EdgeState.alarm}

# In-memory state of this single hub process: availability seen before a node
# registered (base -> online), and the last presence reading per node.
_pending_availability: dict[str, bool] = {}
_last_presence: dict[str, tuple[float, float]] = {}  # node_id -> (value, monotonic ts)


def reset_state() -> None:
    """Forget the in-memory state (tests)."""
    _pending_availability.clear()
    _last_presence.clear()


# --------------------------------------------------------------------------- #
# Pure translation
# --------------------------------------------------------------------------- #
def node_id_for(base: str) -> str:
    """Base topic lowercased, runs of non [a-z0-9] replaced by '-', trimmed."""
    return re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")


def _reject_constant(name: str) -> None:
    raise ValueError(f"non-finite JSON constant {name}")


def _shallow(value: object, depth: int = 0) -> bool:
    children: Iterable[object]
    if isinstance(value, dict):
        children = value.values()
    elif isinstance(value, list):
        children = value
    else:
        return True
    return depth < MAX_DEPTH and all(_shallow(child, depth + 1) for child in children)


def parse_document(raw: bytes) -> object | None:
    """The JSON value of a message, or None (oversized, not JSON, NaN/Infinity, too deep)."""
    if len(raw) > MAX_PAYLOAD_BYTES:
        return None
    try:
        doc = json.loads(raw, parse_constant=_reject_constant)
    except (ValueError, RecursionError):
        return None
    return doc if _shallow(doc) else None


def detect_kind(doc: object) -> NodeKind | None:
    """air: has co/gas/particulate objects; water: has sensor/valve objects."""
    if not isinstance(doc, dict):
        return None
    if all(isinstance(doc.get(k), dict) for k in ("co", "gas", "particulate")):
        return NodeKind.air
    if all(isinstance(doc.get(k), dict) for k in ("sensor", "valve")):
        return NodeKind.water
    return None


def uptime_ms(doc: dict) -> int | None:
    value = doc.get("uptime_ms")
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < 2**63:
        return None
    return value


def _text(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return "".join(ch for ch in value if ch.isprintable()).strip()[:_TEXT_MAX]


def device_field(doc: dict, key: str) -> str:
    """`device.name` / `device.firmware` as clean text ('' when absent)."""
    device = doc.get("device")
    return _text(device.get(key)) if isinstance(device, dict) else ""


def _air_hazard(channel: str, obj: object) -> tuple[float, EdgeState, ReadingThresholds] | None:
    if not isinstance(obj, dict):
        return None
    state = obj.get("state")
    if not isinstance(state, str) or state not in _EDGE_BY_STATE:
        return None  # warmup / fault / unknown
    if "valid" in obj and obj["valid"] is not True:  # gas has no `valid` flag
        return None
    value_key, _, warn_key, danger_key = _AIR_HAZARDS[channel]
    value = finite_number(obj.get(value_key))
    warn = finite_number(obj.get(warn_key))
    danger = finite_number(obj.get(danger_key))
    if value is None or warn is None or danger is None:
        return None
    # The device's own calibration: detect and clear at warn, critical at danger.
    return value, _EDGE_BY_STATE[state], ReadingThresholds(detection=warn, critical=danger, clear=warn)


def _presence(obj: object) -> float | None:
    if not isinstance(obj, dict) or obj.get("valid") is not True:
        return None
    detected = obj.get("detected")
    if not isinstance(detected, bool):
        return None
    return 1.0 if detected else 0.0


def _leak(sensor: object) -> float | None:
    if not isinstance(sensor, dict) or sensor.get("initialized") is not True:
        return None
    state = sensor.get("state")
    if state == "wet":
        return 1.0
    if state == "dry":
        return 0.0
    return None  # uninitialized / unknown


def _signal(doc: dict) -> Signal | None:
    wifi = doc.get("wifi")
    rssi = finite_number(wifi.get("rssi")) if isinstance(wifi, dict) else None
    return Signal(rssi=rssi, link="wifi") if rssi is not None else None


def status_to_payloads(
    kind: NodeKind, doc: dict, *, node_id: str, location: Location, epoch: int, seq: int
) -> list[TelemetryPayload]:
    """Canonical readings for one status document (docs/HARDWARE.md section 2).

    Channels in warm-up / fault or flagged invalid produce no reading (they stay in
    the raw snapshot). Air hazard readings carry the device's own thresholds; the
    water leak reading uses the backend defaults.
    """
    signal = _signal(doc)
    firmware = device_field(doc, "firmware")

    def make(channel: str, sensor_type: SensorType, value: float, units: str,
             edge_state: EdgeState, thresholds: ReadingThresholds | None = None) -> TelemetryPayload:
        return TelemetryPayload(
            device_id=f"{node_id}:{channel}",
            sensor_type=sensor_type,
            location=location,
            value=value,
            units=units,
            edge_state=edge_state,
            signal=signal,
            fw_version=firmware,
            epoch=epoch,
            seq=seq,
            thresholds=thresholds,
        )

    out: list[TelemetryPayload] = []
    if kind == NodeKind.air:
        for channel, sensor_type in NODE_CHANNELS[kind]:
            if channel == "presence":
                present = _presence(doc.get("presence"))
                if present is not None:
                    out.append(make(channel, sensor_type, present, "persons_est", EdgeState.normal))
                continue
            reading = _air_hazard(channel, doc.get(channel))
            if reading is not None:
                value, edge_state, thresholds = reading
                out.append(make(channel, sensor_type, value, _AIR_HAZARDS[channel][1], edge_state, thresholds))
    else:
        wet = _leak(doc.get("sensor"))
        if wet is not None:
            edge_state = EdgeState.alarm if wet else EdgeState.normal
            out.append(make("leak", SensorType.water_leak, wet, "bool", edge_state))
    return out


# --------------------------------------------------------------------------- #
# MQTT handlers
# --------------------------------------------------------------------------- #
async def handle_hardware_message(topic: str, raw: bytes, *, retain: bool = False) -> None:
    """Handle `<base>/status` or `<base>/availability`; other topics are ignored.

    `retain` is the MQTT retained flag (a re-delivered stored message, e.g. on hub
    reconnect). Logs and drops bad input; never raises.
    """
    try:
        if topic.endswith("/status"):
            base, handler = topic[: -len("/status")], _handle_status
        elif topic.endswith("/availability"):
            base, handler = topic[: -len("/availability")], _handle_availability
        else:
            return
        if not base or len(base) > MAX_BASE_LEN:
            log.warning("dropping message on %r: unusable base topic", topic[:200])
            return
        await handler(base, raw, retain)
    except Exception:  # noqa: BLE001 - trust boundary: never crash the consumer
        log.exception("dropping message on %r", topic[:200])


async def _handle_status(base: str, raw: bytes, retain: bool) -> None:
    doc = parse_document(raw)
    kind = detect_kind(doc)
    if kind is None or not isinstance(doc, dict):
        log.debug("ignoring non-hardware document on %r/status", base)
        return
    uptime = uptime_ms(doc)
    if uptime is None:
        log.warning("dropping %s status from %r: missing or invalid uptime_ms", kind.value, base)
        return

    now = datetime.now(timezone.utc)
    async with SessionLocal() as session:
        node = await session.scalar(select(Node).where(Node.mqtt_base == base))
        if node is None:
            node = await _register(session, base, kind, doc, now)
            if node is None:
                return
        elif node.kind != kind.value:
            log.warning("dropping %s status from %r: node %s is %s (base topics must be unique)",
                        kind.value, base, node.id, node.kind)
            return
        elif uptime == node.last_uptime_ms:
            return  # duplicate: retained re-delivery of a document already stored
        elif node.last_uptime_ms is not None and uptime < node.last_uptime_ms:
            node.boot_epoch += 1  # rebooted (or the 32-bit uptime wrapped): new epoch
            log.info("node %s rebooted; boot_epoch %d", node.id, node.boot_epoch)

        node.last_uptime_ms = uptime
        node.last_status = doc
        node.firmware = device_field(doc, "firmware") or node.firmware
        if not retain:  # a live document proves the device is up; a retained one may be old
            node.online = True
            node.last_seen_ts = now
        session.add(NodeStatus(node_id=node.id, ts=now, uptime_ms=uptime, payload=doc))
        zone = await session.get(Zone, node.zone_id)
        await session.commit()

    if zone is None:
        log.warning("node %s: zone %s not found; raw status stored, no readings", node.id, node.zone_id)
        payloads = []
    else:
        location = Location(building_id=zone.building_id, floor_id=zone.floor_id, unit_id=zone.unit_id, zone_id=zone.id)
        payloads = status_to_payloads(kind, doc, node_id=node.id, location=location, epoch=node.boot_epoch, seq=uptime)

    for payload in payloads:
        presence = payload.sensor_type == SensorType.radar_presence
        if presence and not _presence_due(node.id, payload.value):
            continue
        try:
            async with SessionLocal() as session:
                result = await ingest_telemetry(session, payload)
        except Exception:  # noqa: BLE001 - one failing channel must not block the others
            log.exception("ingest failed for %s", payload.device_id)
            continue
        if presence:
            _last_presence[node.id] = (payload.value, time.monotonic())
        if result.incident_state:
            log.info("incident %s -> %s (%s)", result.incident_id, result.incident_state, payload.device_id)

    await _sync_devices(node)
    await broadcast_node(node)


async def _handle_availability(base: str, raw: bytes, retain: bool) -> None:
    text = raw.strip().decode("ascii", "replace") if len(raw) <= 32 else ""
    if text not in ("online", "offline"):
        log.debug("ignoring availability payload on %r", base)
        return
    online = text == "online"
    async with SessionLocal() as session:
        node = await session.scalar(select(Node).where(Node.mqtt_base == base))
        if node is None:
            _remember_availability(base, online)
            return
        node.online = online
        await session.commit()
    await _sync_devices(node)
    await broadcast_node(node)


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
async def _register(session: AsyncSession, base: str, kind: NodeKind, doc: dict, now: datetime) -> Node | None:
    """Create the node + its channel Device rows in the default building/zone."""
    zone = await _landing_zone(session)
    if zone is None:
        log.warning("cannot register node %r: building %r has no zone (CANARY_DEFAULT_BUILDING_ID/_ZONE_ID)",
                    base, settings.default_building_id)
        return None
    if (await session.scalar(select(func.count()).select_from(Node)) or 0) >= MAX_NODES:
        log.warning("cannot register node %r: node limit (%d) reached", base, MAX_NODES)
        return None

    node_id = node_id_for(base) or "node"
    if await session.get(Node, node_id) is not None:  # slug clash with a different base
        node_id = f"{node_id}-{hashlib.sha1(base.encode(), usedforsecurity=False).hexdigest()[:6]}"
    firmware = device_field(doc, "firmware")
    node = Node(
        id=node_id,
        kind=kind.value,
        mqtt_base=base,
        name=device_field(doc, "name") or base[:_TEXT_MAX],
        firmware=firmware,
        building_id=zone.building_id,
        zone_id=zone.id,
        online=_pending_availability.pop(base, True),
        last_seen_ts=now,  # even when retained: the node has just been discovered
        boot_epoch=1,
        created_ts=now,
    )
    session.add(node)
    for channel, sensor_type in NODE_CHANNELS[kind]:
        await session.merge(
            Device(
                id=f"{node_id}:{channel}",
                building_id=zone.building_id,
                floor_id=zone.floor_id,
                unit_id=zone.unit_id,
                zone_id=zone.id,
                sensor_type=sensor_type.value,
                fw_version=firmware,
                status="ok" if node.online else "offline",
                last_seen_ts=now,
            )
        )
    log.info("registered %s node %s (base %r) in %s/%s", kind.value, node_id, base, zone.building_id, zone.id)
    return node


async def _landing_zone(session: AsyncSession) -> Zone | None:
    """The configured default zone, else the default building's first zone."""
    zone = await session.get(Zone, settings.default_zone_id)
    if zone is not None and zone.building_id == settings.default_building_id:
        return zone
    return await session.scalar(
        select(Zone).where(Zone.building_id == settings.default_building_id).order_by(Zone.id).limit(1)
    )


async def _sync_devices(node: Node) -> None:
    """Mirror the node's liveness onto its Device rows (after ingestion, which touches
    their last_seen_ts, so a retained document never refreshes it)."""
    async with SessionLocal() as session:
        await session.execute(
            update(Device)
            .where(Device.id.in_(device_ids(node.id, node.kind)))
            .values(
                status="ok" if node.online else "offline",
                last_seen_ts=node.last_seen_ts,
                fw_version=node.firmware,
            )
        )
        await session.commit()


def _presence_due(node_id: str, value: float) -> bool:
    last = _last_presence.get(node_id)
    return last is None or last[0] != value or time.monotonic() - last[1] >= PRESENCE_REFRESH_S


def _remember_availability(base: str, online: bool) -> None:
    _pending_availability.pop(base, None)
    if len(_pending_availability) >= MAX_PENDING_AVAILABILITY:
        _pending_availability.pop(next(iter(_pending_availability)))  # forget the oldest
    _pending_availability[base] = online
