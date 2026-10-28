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
from app import firmware
from app.analytics.nodes import broadcast_node, device_ids
from app.config import settings
from app.db import SessionLocal, engine
from app.enums import NODE_CHANNELS, EdgeState, NodeKind, SensorType
from app.ingestion.pipeline import ingest_telemetry
from app.models import Device, Node, NodeFirmwareSeen, NodeInbox, NodeStatus, Zone
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
# A contact reads 1 (alarm or open wiring) or 0, so anything open is critical. Explicit so the
# combustible_gas ppm defaults never apply to a boolean.
_GAS_DETECTOR_THRESHOLDS = ReadingThresholds(detection=0.5, critical=1.0, clear=0.5)
# device channel grading -> edge state; warmup / fault produce no reading
_EDGE_BY_STATE = {"ok": EdgeState.normal, "warning": EdgeState.warn, "danger": EdgeState.alarm}

# In-memory state of this single hub process: availability seen before a node
# registered (base -> online), and the last presence reading per node.
_pending_availability: dict[str, bool] = {}
_last_presence: dict[str, tuple[float, float]] = {}  # node_id -> (value, monotonic ts)
_channels_checked: set[str] = set()  # node_ids whose channel Device rows are known to exist


def reset_state() -> None:
    """Forget the in-memory state (tests)."""
    _pending_availability.clear()
    _last_presence.clear()
    _channels_checked.clear()


def forget_node(node_id: str, base: str) -> None:
    """Drop a deleted node's in-memory state, so its base topic registers afresh."""
    _pending_availability.pop(base, None)
    _last_presence.pop(node_id, None)
    _channels_checked.discard(node_id)


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


def _gas_detector(obj: object) -> float | None:
    """Firmware 1.1.0+: the external detector's contact. Older firmware sends no object."""
    if not isinstance(obj, dict):
        return None
    alarm = obj.get("alarm")
    if not isinstance(alarm, bool):
        return None
    return 1.0 if alarm else 0.0


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
            if channel == "gas_detector":
                open_contact = _gas_detector(doc.get("gas_detector"))
                if open_contact is not None:
                    edge_state = EdgeState.alarm if open_contact else EdgeState.normal
                    out.append(make(channel, sensor_type, open_contact, "bool", edge_state,
                                    _GAS_DETECTOR_THRESHOLDS))
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
async def handle_hardware_message(
    topic: str, raw: bytes, *, retain: bool = False, received_ts: float | None = None
) -> None:
    """Handle `<base>/status` or `<base>/availability`; other topics are ignored.

    `retain` is the MQTT retained flag (a re-delivered stored message, e.g. on hub
    reconnect). `received_ts` (epoch s) is when the MQTT client received it, so a processing
    backlog never ages `last_seen`; default now. Logs and drops bad input; never raises.
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
        received = datetime.fromtimestamp(received_ts, timezone.utc) if received_ts else datetime.now(timezone.utc)
        await handler(base, raw, retain, received)
    except Exception:  # noqa: BLE001 - trust boundary: never crash the consumer
        log.exception("dropping message on %r", topic[:200])


async def _handle_status(base: str, raw: bytes, retain: bool, now: datetime) -> None:
    doc = parse_document(raw)
    kind = detect_kind(doc)
    if kind is None or not isinstance(doc, dict):
        log.debug("ignoring non-hardware document on %r/status", base)
        return
    uptime = uptime_ms(doc)
    if uptime is None:
        log.warning("dropping %s status from %r: missing or invalid uptime_ms", kind.value, base)
        return

    # One connection + session for the whole document (the status row, then one transaction per
    # channel): on a Pi every pool checkout and statement is a thread round trip.
    async with engine.connect() as conn, AsyncSession(bind=conn, expire_on_commit=False) as session:
        row = (
            await session.execute(
                select(Node, Zone).outerjoin(Zone, Zone.id == Node.zone_id).where(Node.mqtt_base == base)
            )
        ).first()
        node, zone = row if row is not None else (None, None)
        previous_firmware, rebooted = node.firmware if node is not None else "", False
        if node is None:
            node = await _register(session, base, kind, doc, now)
            if node is None:
                return
            zone = await session.get(Zone, node.zone_id)
        elif node.kind != kind.value:
            log.warning("dropping %s status from %r: node %s is %s (base topics must be unique)",
                        kind.value, base, node.id, node.kind)
            return
        elif retain and settings.cluster_mode == "triple":
            return  # another Pi's broker may hold an old copy; the next live document follows within 15-60 s
        elif uptime == node.last_uptime_ms:
            return  # duplicate: retained re-delivery of a document already stored
        elif node.last_uptime_ms is not None and uptime < node.last_uptime_ms:
            node.boot_epoch += 1  # rebooted (or the 32-bit uptime wrapped): new epoch
            rebooted = not retain
            log.info("node %s rebooted; boot_epoch %d", node.id, node.boot_epoch)

        node.last_uptime_ms = uptime
        node.last_status = doc
        node.firmware = device_field(doc, "firmware") or node.firmware
        if node.firmware and node.firmware != previous_firmware:
            session.add(NodeFirmwareSeen(node_id=node.id, firmware=node.firmware, ts=now))
        if not retain:  # a live document proves the device is up; a retained one may be old
            node.online = True
            node.last_seen_ts = now
        session.add(NodeStatus(node_id=node.id, ts=now, uptime_ms=uptime, payload=doc))
        if zone is not None and node.id not in _channels_checked:
            await _add_missing_devices(session, node, kind, zone, now)
            _channels_checked.add(node.id)
        await session.execute(_device_liveness(node))  # mirror liveness onto the node's Device rows
        await session.commit()
        session.expunge(node)  # keep the loaded node usable after the channel transactions

        if zone is None:
            log.warning("node %s: zone %s not found; raw status stored, no readings", node.id, node.zone_id)
            payloads = []
        else:
            location = Location(building_id=zone.building_id, floor_id=zone.floor_id, unit_id=zone.unit_id,
                                zone_id=zone.id)
            payloads = status_to_payloads(kind, doc, node_id=node.id, location=location, epoch=node.boot_epoch,
                                          seq=uptime)

        for payload in payloads:
            presence = payload.sensor_type == SensorType.radar_presence
            if presence and not _presence_due(node.id, payload.value):
                continue
            try:
                # Already deduplicated by uptime above, and liveness is set; each channel commits on
                # its own, and expire_all() makes the next one read fresh rows like a new session.
                result = await ingest_telemetry(session, payload, dedupe=False, touch_device=False, received_ts=now)
            except Exception:  # noqa: BLE001 - one failing channel must not block the others
                await session.rollback()
                log.exception("ingest failed for %s", payload.device_id)
                continue
            finally:
                session.expire_all()
            if presence:
                _last_presence[node.id] = (payload.value, time.monotonic())
            if result.incident_state:
                log.info("incident %s -> %s (%s)", result.incident_id, result.incident_state, payload.device_id)

    await broadcast_node(node)
    if rebooted:
        await firmware.confirm_reboot(node, now)


async def _handle_availability(base: str, raw: bytes, retain: bool, now: datetime) -> None:
    text = raw.strip().decode("ascii", "replace") if len(raw) <= 32 else ""
    if text not in ("online", "offline"):
        log.debug("ignoring availability payload on %r", base)
        return
    online = text == "online"
    if retain and online and settings.cluster_mode == "triple":
        return  # may be an old copy on another Pi's broker; a live status document proves "online"
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
    session.add(NodeInbox(node_id=node_id, ts=now))  # waits for a technician to place it
    for channel, sensor_type in NODE_CHANNELS[kind]:
        await session.merge(_channel_device(node, channel, sensor_type, zone, now))
    log.info("registered %s node %s (base %r) in %s/%s", kind.value, node_id, base, zone.building_id, zone.id)
    return node


def _channel_device(node: Node, channel: str, sensor_type: SensorType, zone: Zone, now: datetime) -> Device:
    return Device(
        id=f"{node.id}:{channel}",
        building_id=zone.building_id,
        floor_id=zone.floor_id,
        unit_id=zone.unit_id,
        zone_id=zone.id,
        sensor_type=sensor_type.value,
        fw_version=node.firmware,
        status="ok" if node.online else "offline",
        last_seen_ts=now,
    )


async def _add_missing_devices(session: AsyncSession, node: Node, kind: NodeKind, zone: Zone, now: datetime) -> None:
    """Device rows for channels added after the node registered (e.g. gas_detector); checked
    once per node per process, so a status document normally costs no extra query."""
    ids = device_ids(node.id, kind.value)
    existing = set((await session.scalars(select(Device.id).where(Device.id.in_(ids)))).all())
    for channel, sensor_type in NODE_CHANNELS[kind]:
        if f"{node.id}:{channel}" not in existing:
            session.add(_channel_device(node, channel, sensor_type, zone, now))


async def _landing_zone(session: AsyncSession) -> Zone | None:
    """The configured default zone, else the default building's first zone."""
    zone = await session.get(Zone, settings.default_zone_id)
    if zone is not None and zone.building_id == settings.default_building_id:
        return zone
    return await session.scalar(
        select(Zone).where(Zone.building_id == settings.default_building_id).order_by(Zone.id).limit(1)
    )


def _device_liveness(node: Node):
    """UPDATE mirroring the node's liveness onto its Device rows (a retained document never
    refreshes last_seen_ts: the node's own value is copied)."""
    return (
        update(Device)
        .where(Device.id.in_(device_ids(node.id, node.kind)))
        .values(status="ok" if node.online else "offline", last_seen_ts=node.last_seen_ts, fw_version=node.firmware)
    )


async def _sync_devices(node: Node) -> None:
    async with SessionLocal() as session:
        await session.execute(_device_liveness(node))
        await session.commit()


def _presence_due(node_id: str, value: float) -> bool:
    last = _last_presence.get(node_id)
    return last is None or last[0] != value or time.monotonic() - last[1] >= PRESENCE_REFRESH_S


def _remember_availability(base: str, online: bool) -> None:
    _pending_availability.pop(base, None)
    if len(_pending_availability) >= MAX_PENDING_AVAILABILITY:
        _pending_availability.pop(next(iter(_pending_availability)))  # forget the oldest
    _pending_availability[base] = online
