"""Hardware node views: analysis, building summary, raw history (docs/HARDWARE.md 3-5).

DB-backed glue around the pure analysis in app.analytics.environment. Kept cheap
for a Raspberry Pi: trends come from the canonical readings (plain columns, no JSON
parsing) and history streams its window once, keeping only the open time bucket.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Sequence
from dataclasses import asdict, replace
from datetime import datetime, timedelta, timezone

from sqlalchemy import Float, cast, delete, func, literal, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.environment import (
    TREND_WINDOW_S,
    NodeAnalysis,
    OpenIncident,
    TrendFit,
    analyze_node,
    finite_number,
    summarize_building,
    utc,
)
from app.enums import NODE_CHANNELS, OPEN_INCIDENT_STATES, NodeKind
from app.models import Device, Incident, Node, NodeInbox, NodeStatus, SensorReading, Unit, Zone
from app.notify.service import incident_title
from app.realtime.ws import manager
from app.schemas import BuildingSummaryOut, HistoryPoint, NodeAnalysisOut, NodeOut

log = logging.getLogger("canary.nodes")

MAX_HISTORY_POINTS = 360
MAX_HISTORY_FIELDS = 20
DEFAULT_HISTORY_FIELDS = {
    "air": [
        "co.ppm",
        "gas.adc",
        "particulate.pm1_0",
        "particulate.pm2_5",
        "particulate.pm10",
        "climate.temperature_c",
        "climate.humidity_percent",
        "presence.detected",
    ],
    "water": ["sensor.adc", "leak_latched"],
}
# Residents (mobile charts) get environmental fields and the device thresholds only: never
# presence/radar (who is home), Wi-Fi or device internals. Their defaults are the kind's
# defaults within this list (no thresholds).
RESIDENT_HISTORY_FIELDS = {
    "air": [f for f in DEFAULT_HISTORY_FIELDS["air"] if not f.startswith("presence.")] + [
        "co.warn_ppm", "co.danger_ppm", "gas.warn_adc", "gas.danger_adc", "particulate.warn_pm2_5",
        "particulate.danger_pm2_5", "particulate.warn_pm10", "particulate.danger_pm10",
    ],
    "water": DEFAULT_HISTORY_FIELDS["water"] + ["sensor.wet_threshold", "sensor.dry_threshold"],
}
# Bucket aggregation: hazard / level fields keep the MAX so short spikes survive; any other
# number is the MEAN (0.1); text keeps the newest value.
_MAX_PREFIXES = ("co.", "gas.", "particulate.")
_MAX_FIELDS = frozenset({"sensor.adc", "sensor.wet_threshold", "sensor.dry_threshold", "leak_latched",
                         "presence.detected"})
# A channel's measurements are null while it is warming up, faulty, invalid or uninitialized;
# its flags and thresholds stay readable.
_UNTRUSTED_STATES = ("warmup", "fault", "uninitialized")
_UNGATED_KEYS = ("state", "valid", "initialized", "age_ms")
_FIELD_RE = re.compile(r"[A-Za-z0-9_]{1,32}(\.[A-Za-z0-9_]{1,32}){0,3}")

# canonical reading channel -> trend field carrying the same raw value
_TREND_CHANNELS = {"co": "co.ppm", "gas": "gas.adc", "particulate": "particulate.pm2_5"}


def device_ids(node_id: str, kind: str) -> list[str]:
    """Ids of the logical Device rows a node owns."""
    return [f"{node_id}:{channel}" for channel, _ in NODE_CHANNELS[NodeKind(kind)]]


def analyze(node: Node, now: datetime, history: dict | None = None) -> NodeAnalysis:
    return analyze_node(
        node_id=node.id,
        kind=node.kind,
        name=node.name,
        zone_id=node.zone_id,
        online=node.online,
        last_seen_ts=node.last_seen_ts,
        status=node.last_status,
        now=now,
        history=history,
    )


def _is_presence(field: str) -> bool:
    return field == "presence" or field.startswith("presence.")


def parse_fields(raw: str | None, kind: str, resident: bool = False, presence: bool = True) -> list[str]:
    """History fields: comma-separated dotted paths, or the kind's defaults. Residents are
    limited to RESIDENT_HISTORY_FIELDS (anything else: ValueError). Without `presence`
    (dispatchers) the defaults leave out presence.* and asking for it is a PermissionError."""
    allowed = RESIDENT_HISTORY_FIELDS[kind] if resident else None
    if raw is None or not raw.strip():
        return [
            f for f in DEFAULT_HISTORY_FIELDS[kind]
            if (allowed is None or f in allowed) and (presence or not _is_presence(f))
        ]
    fields = list(dict.fromkeys(f.strip() for f in raw.split(",") if f.strip()))
    if len(fields) > MAX_HISTORY_FIELDS or not all(_FIELD_RE.fullmatch(f) for f in fields):
        raise ValueError(f"fields must be at most {MAX_HISTORY_FIELDS} dotted paths such as co.ppm")
    refused = [f for f in fields if allowed is not None and f not in allowed]
    if refused:
        raise ValueError(f"fields not available: {', '.join(refused)}; allowed: {', '.join(allowed or ())}")
    if not presence and any(_is_presence(f) for f in fields):
        raise PermissionError("presence history is not available to dispatchers")
    return fields


def extract(doc: object, path: str) -> int | float | str | None:
    """Value at a dotted path of a raw document: booleans as 0/1, containers/missing as None."""
    value = doc
    for part in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(part)
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float, str)):
        return value
    return None


def history_value(doc: object, path: str) -> int | float | str | None:
    """extract(), but null for a measurement whose channel is not trustworthy in this
    document (state warmup/fault/uninitialized, valid or initialized false)."""
    head, _, rest = path.partition(".")
    channel = doc.get(head) if isinstance(doc, dict) else None
    if rest and isinstance(channel, dict):
        key = rest.partition(".")[0]
        setting = key in _UNGATED_KEYS or key.startswith(("warn_", "danger_")) or key.endswith("_threshold")
        if not setting and (
            channel.get("state") in _UNTRUSTED_STATES
            or channel.get("valid") is False
            or channel.get("initialized") is False
        ):
            return None
    return extract(doc, path)


def aggregate(field: str, values: Sequence[int | float | str | None]) -> int | float | str | None:
    """One bucket's value: MAX for hazard / level fields, MEAN rounded to 0.1 for other numbers,
    the newest value for text. Nulls are ignored; an all-null bucket is null (a gap)."""
    present = [v for v in values if v is not None]
    numbers = [v for v in present if not isinstance(v, str) and finite_number(v) is not None]
    if not numbers:
        return next((v for v in reversed(present) if isinstance(v, str)), None)
    if len(numbers) == 1:
        return numbers[0]
    if field.startswith(_MAX_PREFIXES) or field in _MAX_FIELDS:
        return max(numbers)
    return round(sum(numbers) / len(numbers), 1)


def _bucket_point(rows: Sequence[tuple[datetime, dict]], fields: Sequence[str]) -> HistoryPoint:
    """A bucket's point, stamped with its newest sample."""
    return HistoryPoint(ts=rows[-1][0], values={f: aggregate(f, [values[f] for _, values in rows]) for f in fields})


def _iso_z(ts: datetime) -> str:
    return utc(ts).isoformat().replace("+00:00", "Z")


async def broadcast_node(node: Node, now: datetime | None = None) -> None:
    """Push the analysis-only `node` event to the building's WebSocket room. Best-effort:
    a failure here must never break ingestion."""
    try:
        now = now or datetime.now(timezone.utc)
        await manager.broadcast(
            node.building_id,
            {
                "type": "node",
                "building_id": node.building_id,
                "node_id": node.id,
                "kind": node.kind,
                "zone_id": node.zone_id,
                "online": node.online,
                "status": analyze(node, now).status,
                "ts": _iso_z(now),
            },
        )
    except Exception:  # noqa: BLE001
        log.exception("node event broadcast failed for %s", node.id)


class NodeService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def _trend_history(self, nodes: Sequence[Node], now: datetime) -> dict[str, dict[str, TrendFit]]:
        """node_id -> trend field -> least-squares fit over the trend window. The database sums
        each series (one row per device instead of every reading: the summary and the nodes list
        are polled by every dashboard); the slope is the same as fitting the points."""
        wanted = {
            f"{n.id}:{channel}": (n.id, field)
            for n in nodes
            if n.kind == NodeKind.air.value
            for channel, field in _TREND_CHANNELS.items()
        }
        if not wanted:
            return {}
        since = now - timedelta(seconds=TREND_WINDOW_S)
        t = self._seconds_since(SensorReading.ts, since)  # small numbers: no cancellation in the sums
        v = SensorReading.value
        rows = await self.session.execute(
            select(SensorReading.device_id, func.count(), func.sum(t), func.sum(v), func.sum(t * t),
                   func.sum(t * v), func.min(t), func.max(t))
            .where(SensorReading.device_id.in_(list(wanted)), SensorReading.ts >= since)
            .group_by(SensorReading.device_id)
        )
        history: dict[str, dict[str, TrendFit]] = {}
        for device_id, n, st, sv, stt, stv, t_min, t_max in rows:
            denom = n * stt - st * st
            slope = (n * stv - st * sv) / denom if n >= 2 and abs(denom) > 1e-9 else 0.0
            node_id, field = wanted[device_id]
            history.setdefault(node_id, {})[field] = TrendFit(n, t_max - t_min, slope)
        return history

    def _seconds_since(self, column, since: datetime):
        """SQL: seconds from `since` to `column` (SQLite stores timestamps as text)."""
        if self.session.bind.dialect.name == "sqlite":
            anchor = literal(utc(since).strftime("%Y-%m-%d %H:%M:%S.%f"))
            return (func.julianday(column) - func.julianday(anchor)) * 86400.0
        # EXTRACT is numeric on Postgres: the driver's Decimal sums would not mix with the float ones
        return cast(func.extract("epoch", column - literal(utc(since))), Float)

    async def analyses(self, nodes: Sequence[Node], now: datetime) -> dict[str, NodeAnalysis]:
        history = await self._trend_history(nodes, now)
        return {n.id: analyze(n, now, history.get(n.id)) for n in nodes}

    async def node_outs(self, nodes: Sequence[Node]) -> list[NodeOut]:
        analyses = await self.analyses(nodes, datetime.now(timezone.utc))
        return [
            NodeOut(
                id=n.id,
                kind=n.kind,
                mqtt_base=n.mqtt_base,
                name=n.name,
                firmware=n.firmware,
                building_id=n.building_id,
                zone_id=n.zone_id,
                online=n.online,
                last_seen_ts=utc(n.last_seen_ts) if n.last_seen_ts is not None else None,
                boot_epoch=n.boot_epoch,
                status=n.last_status,
                analysis=NodeAnalysisOut.model_validate(asdict(analyses[n.id])),
            )
            for n in nodes
        ]

    async def building_nodes(self, building_id: str) -> list[Node]:
        return list(
            (
                await self.session.scalars(
                    select(Node).where(Node.building_id == building_id).order_by(Node.name, Node.id)
                )
            ).all()
        )

    async def building_summary(self, building_id: str, zone_ids: set[str] | None = None) -> BuildingSummaryOut:
        """With `zone_ids` (a resident's zones) only those zones are listed and counted, and
        their nodes alone decide the status and headline, unless an incident is open anywhere
        in the building: then status, headline and incident count stay whole-building."""
        now = datetime.now(timezone.utc)
        nodes = await self.building_nodes(building_id)
        analyses = await self.analyses(nodes, now)
        rows = (
            await self.session.execute(
                select(Zone.id, Zone.label, Zone.unit_id, Unit.label)
                .outerjoin(Unit, Unit.id == Zone.unit_id)
                .where(Zone.building_id == building_id)
            )
        ).all()
        zone_labels: dict[str, str] = {zone_id: label for zone_id, label, _, _ in rows}
        # the flat of each room, so clients can group rooms that share a name ("Bucătărie")
        zone_units = {zone_id: (unit_id, unit_label) for zone_id, _, unit_id, unit_label in rows}
        incidents = (
            await self.session.scalars(
                select(Incident).where(
                    Incident.building_id == building_id,
                    Incident.state.in_([s.value for s in OPEN_INCIDENT_STATES]),
                )
            )
        ).all()
        summary = summarize_building(
            building_id=building_id,
            generated_ts=now,
            nodes=list(analyses.values()),
            zone_labels=zone_labels,
            incidents=[OpenIncident(i.state, i.severity, incident_title(i), i.opened_ts) for i in incidents],
        )
        if zone_ids is not None:
            scoped = summarize_building(
                building_id=building_id,
                generated_ts=now,
                nodes=[a for a in analyses.values() if a.zone_id in zone_ids],
                zone_labels=zone_labels,
                incidents=[],
            )
            if incidents:
                scoped = replace(scoped, status=summary.status, headline=summary.headline,
                                 active_incidents=summary.active_incidents)
            summary = scoped
        out = asdict(summary)
        for zone in out["zones"]:
            zone["unit_id"], zone["unit_label"] = zone_units.get(zone["zone_id"], (None, None))
        return BuildingSummaryOut.model_validate(out)

    async def history(self, node: Node, minutes: int, fields: list[str]) -> list[HistoryPoint]:
        """Snapshots of the last `minutes`. Up to 360 come back as they are; a longer window is
        split into 360 equal time buckets, one aggregated point per non-empty bucket stamped
        with its newest sample, so a short spike is never dropped. One streamed pass that
        holds only the open bucket."""
        since = datetime.now(timezone.utc) - timedelta(minutes=minutes)
        width_s = minutes * 60 / MAX_HISTORY_POINTS
        raw: list[HistoryPoint] | None = []  # None once the window holds more than 360
        points: list[HistoryPoint] = []
        bucket: list[tuple[datetime, dict]] = []
        bucket_key = -1
        rows = await self.session.stream(
            select(NodeStatus.ts, NodeStatus.payload)
            .where(NodeStatus.node_id == node.id, NodeStatus.ts >= since)
            .order_by(NodeStatus.ts, NodeStatus.id)
            .execution_options(yield_per=500)
        )
        async for ts, payload in rows:
            ts = utc(ts)
            values = {f: history_value(payload, f) for f in fields}
            if raw is not None:
                raw.append(HistoryPoint(ts=ts, values=values))
                raw = raw if len(raw) <= MAX_HISTORY_POINTS else None
            key = min(int((ts - since).total_seconds() // width_s), MAX_HISTORY_POINTS - 1)
            if key != bucket_key and bucket:
                points.append(_bucket_point(bucket, fields))
                bucket = []
            bucket_key = key
            bucket.append((ts, values))
        if bucket:
            points.append(_bucket_point(bucket, fields))
        return raw if raw is not None else points

    async def move(self, node: Node, zone: Zone) -> None:
        """Move a node and its Device rows to `zone` (caller commits). A placed node leaves the inbox."""
        node.building_id = zone.building_id
        node.zone_id = zone.id
        await self.session.execute(delete(NodeInbox).where(NodeInbox.node_id == node.id))
        await self.session.execute(
            update(Device)
            .where(Device.id.in_(device_ids(node.id, node.kind)))
            .values(building_id=zone.building_id, floor_id=zone.floor_id, unit_id=zone.unit_id, zone_id=zone.id)
        )
