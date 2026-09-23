"""Hardware node views: analysis, building summary, raw history (docs/HARDWARE.md 3-5).

DB-backed glue around the pure analysis in app.analytics.environment. Kept cheap
for a Raspberry Pi: trends come from the canonical readings (plain columns, no JSON
parsing) and history thins long windows to <= 360 snapshots before any payload is
loaded and parsed.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Sequence
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from typing import TypeVar

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.environment import (
    TREND_WINDOW_S,
    NodeAnalysis,
    OpenIncident,
    analyze_node,
    summarize_building,
    utc,
)
from app.enums import NODE_CHANNELS, OPEN_INCIDENT_STATES, NodeKind
from app.models import Device, Incident, Node, NodeStatus, SensorReading, Zone
from app.notify.service import incident_title
from app.realtime.ws import manager
from app.schemas import BuildingSummaryOut, HistoryPoint, NodeAnalysisOut, NodeOut

log = logging.getLogger("canary.nodes")

MAX_HISTORY_POINTS = 360
MAX_HISTORY_FIELDS = 16
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
_FIELD_RE = re.compile(r"[A-Za-z0-9_]{1,32}(\.[A-Za-z0-9_]{1,32}){0,3}")

# canonical reading channel -> trend field carrying the same raw value
_TREND_CHANNELS = {"co": "co.ppm", "gas": "gas.adc", "particulate": "particulate.pm2_5"}

T = TypeVar("T")


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


def parse_fields(raw: str | None, kind: str) -> list[str]:
    """History fields: comma-separated dotted paths, or the kind's defaults."""
    if raw is None or not raw.strip():
        return list(DEFAULT_HISTORY_FIELDS[kind])
    fields = list(dict.fromkeys(f.strip() for f in raw.split(",") if f.strip()))
    if len(fields) > MAX_HISTORY_FIELDS or not all(_FIELD_RE.fullmatch(f) for f in fields):
        raise ValueError(f"fields must be at most {MAX_HISTORY_FIELDS} dotted paths such as co.ppm")
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


def thin(items: Sequence[T], limit: int) -> list[T]:
    """At most `limit` items, evenly spaced, keeping the first and the last."""
    if len(items) <= limit:
        return list(items)
    step = (len(items) - 1) / (limit - 1)
    return [items[round(i * step)] for i in range(limit)]


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

    async def _trend_history(self, nodes: Sequence[Node], now: datetime) -> dict[str, dict[str, list]]:
        """node_id -> trend field -> [(epoch_s, value)] over the trend window."""
        wanted = {
            f"{n.id}:{channel}": (n.id, field)
            for n in nodes
            if n.kind == NodeKind.air.value
            for channel, field in _TREND_CHANNELS.items()
        }
        if not wanted:
            return {}
        rows = await self.session.execute(
            select(SensorReading.device_id, SensorReading.ts, SensorReading.value).where(
                SensorReading.device_id.in_(list(wanted)),
                SensorReading.ts >= now - timedelta(seconds=TREND_WINDOW_S),
            )
        )
        history: dict[str, dict[str, list]] = {}
        for device_id, ts, value in rows:
            node_id, field = wanted[device_id]
            history.setdefault(node_id, {}).setdefault(field, []).append((utc(ts).timestamp(), value))
        return history

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

    async def building_summary(self, building_id: str) -> BuildingSummaryOut:
        now = datetime.now(timezone.utc)
        nodes = await self.building_nodes(building_id)
        analyses = await self.analyses(nodes, now)
        rows = await self.session.execute(select(Zone.id, Zone.label).where(Zone.building_id == building_id))
        zone_labels: dict[str, str] = {zone_id: label for zone_id, label in rows}
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
        return BuildingSummaryOut.model_validate(asdict(summary))

    async def history(self, node: Node, minutes: int, fields: list[str]) -> list[HistoryPoint]:
        """Raw snapshots of the last `minutes`, thinned to <= 360 before loading payloads."""
        since = datetime.now(timezone.utc) - timedelta(minutes=minutes)
        ids = (
            await self.session.scalars(
                select(NodeStatus.id)
                .where(NodeStatus.node_id == node.id, NodeStatus.ts >= since)
                .order_by(NodeStatus.ts, NodeStatus.id)
            )
        ).all()
        picked = thin(ids, MAX_HISTORY_POINTS)
        if not picked:
            return []
        rows = await self.session.execute(
            select(NodeStatus.ts, NodeStatus.payload)
            .where(NodeStatus.id.in_(picked))
            .order_by(NodeStatus.ts, NodeStatus.id)
        )
        return [HistoryPoint(ts=utc(ts), values={f: extract(payload, f) for f in fields}) for ts, payload in rows]

    async def move(self, node: Node, zone: Zone) -> None:
        """Move a node and its Device rows to `zone` (caller commits)."""
        node.building_id = zone.building_id
        node.zone_id = zone.id
        await self.session.execute(
            update(Device)
            .where(Device.id.in_(device_ids(node.id, node.kind)))
            .values(building_id=zone.building_id, floor_id=zone.floor_id, unit_id=zone.unit_id, zone_id=zone.id)
        )
