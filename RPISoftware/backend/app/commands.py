"""Device commands: publish to a node's command topic on the local broker, match its
`<base>/command/result` answer (docs/HARDWARE.md section 4).

Topics and payloads follow the firmware (air_sensor / water_sensor README): air `buzzer/set`
TEST | SILENCE and `gas-detector/set` DETECTOR_ON | DETECTOR_OFF; water `valve/set` OPEN | CLOSE
and `buzzer/set` SILENCE; QoS 1, never retained.
Results are `{"command","accepted":true,"state"}` or `{"command","accepted":false,"error"}`;
the latest `sent` command with that name for the node within 30 s takes the result. A command
without an answer for 15 s reads as `timeout` (computed on read, so a late answer within 30 s
still lands).
"""

from __future__ import annotations

import json
import logging
from collections.abc import Sequence
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.enums import NODE_COMMANDS
from app.ingestion import broker
from app.models import AuditLogEntry, DeviceCommand, Node, User
from app.realtime.ws import manager
from app.schemas import CommandOut

log = logging.getLogger("canary.commands")

RESULT_WINDOW = timedelta(seconds=30)
TIMEOUT = timedelta(seconds=15)
MIN_INTERVAL = timedelta(seconds=3)  # between two commands to the same node


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def status_of(command: DeviceCommand, now: datetime | None = None) -> str:
    if command.status == "sent" and (now or _now()) - command.sent_ts > TIMEOUT:
        return "timeout"
    return command.status


async def outs(session: AsyncSession, commands: Sequence[DeviceCommand], *, viewer_id: str | None = None) -> list[
    CommandOut
]:
    """API items. With `viewer_id` (a resident), only their own commands carry the requester's name."""
    ids = {c.requested_by_user_id for c in commands}
    names = {u.id: u.display_name or u.username for u in await session.scalars(select(User).where(User.id.in_(ids)))}
    now = _now()
    return [
        CommandOut(
            command_id=c.id, command=c.command, status=status_of(c, now), detail=c.detail,
            requested_by_name=names.get(c.requested_by_user_id)
            if viewer_id is None or c.requested_by_user_id == viewer_id else None,
            sent_ts=c.sent_ts, result_ts=c.result_ts,
        )
        for c in commands
    ]


async def latest_per_node(session: AsyncSession, node_ids: Sequence[str]) -> dict[str, DeviceCommand]:
    if not node_ids:
        return {}
    newest = (
        select(DeviceCommand.node_id, func.max(DeviceCommand.sent_ts).label("ts"))
        .where(DeviceCommand.node_id.in_(list(node_ids)))
        .group_by(DeviceCommand.node_id)
        .subquery()
    )
    rows = await session.scalars(
        select(DeviceCommand).join(
            newest, (DeviceCommand.node_id == newest.c.node_id) & (DeviceCommand.sent_ts == newest.c.ts)
        )
    )
    return {c.node_id: c for c in rows.all()}


async def too_soon(session: AsyncSession, node_id: str) -> bool:
    """A command went to this node less than MIN_INTERVAL ago."""
    last = await session.scalar(select(func.max(DeviceCommand.sent_ts)).where(DeviceCommand.node_id == node_id))
    return last is not None and _now() - last < MIN_INTERVAL


async def send(session: AsyncSession, node: Node, command: str, user_id: str) -> DeviceCommand:
    """Publish (QoS 1, not retained) and record the command. Raises broker.BrokerUnavailable."""
    topic = f"{node.mqtt_base}/{NODE_COMMANDS[node.kind][command]}"
    await broker.publish(topic, command, qos=1, retain=False)
    row = DeviceCommand(node_id=node.id, building_id=node.building_id, command=command, status="sent",
                        requested_by_user_id=user_id, sent_ts=_now())
    session.add(row)
    await session.flush()
    session.add(AuditLogEntry(actor=user_id, action="device_command", target=node.id,
                              detail={"command": command, "command_id": row.id}))
    await session.commit()
    return row


async def handle_result(base: str, raw: bytes, received_ts: float | None = None) -> None:
    """`<base>/command/result` from a device, matched at its receive time (epoch s; default now),
    so a processing backlog never turns a prompt answer into a timeout. Never raises."""
    try:
        doc = json.loads(raw)
        if not isinstance(doc, dict) or not isinstance(doc.get("command"), str):
            return
        accepted = doc.get("accepted") is True
        detail = doc.get("state" if accepted else "error")
        detail = detail[:64] if isinstance(detail, str) else None
        now = datetime.fromtimestamp(received_ts, timezone.utc) if received_ts else _now()
        async with SessionLocal() as session:
            node = await session.scalar(select(Node).where(Node.mqtt_base == base))
            if node is None:
                return
            command = await session.scalar(
                select(DeviceCommand)
                .where(DeviceCommand.node_id == node.id, DeviceCommand.command == doc["command"],
                       DeviceCommand.status == "sent", DeviceCommand.sent_ts >= now - RESULT_WINDOW)
                .order_by(DeviceCommand.sent_ts.desc())
                .limit(1)
            )
            if command is None:
                log.debug("unmatched command result from %r: %s", base, doc.get("command"))
                return
            command.status, command.detail, command.result_ts = ("accepted" if accepted else "rejected"), detail, now
            await session.commit()
            message = {
                "type": "command_result", "building_id": node.building_id, "node_id": node.id,
                "command_id": command.id, "command": command.command, "status": command.status,
                "detail": detail, "ts": _iso(now),
            }
        await manager.broadcast(message["building_id"], message)
    except Exception:  # noqa: BLE001 - trust boundary: never crash the consumer
        log.exception("dropping command result on %r", base[:200])
