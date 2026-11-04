"""Device command endpoints (hardware test from the dashboard / app), docs/HARDWARE.md section 4.

Roles: system_admin any node; hoa_manager/technician nodes of the buildings they run; resident only nodes in
zones of their own units (never common areas); detector settings are staff-only. Others 403.
Out-of-scope nodes are a 404.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import commands
from app.api.scope import managed_buildings, manages
from app.db import get_session
from app.enums import NODE_COMMANDS, Role
from app.ingestion import broker
from app.models import DeviceCommand, Node, ResidentUnit, Zone
from app.schemas import CommandIn, CommandOut, CommandSentOut
from app.security import Principal, get_current_principal

router = APIRouter(prefix="/api/v1", tags=["nodes"])


async def _commandable_node(session: AsyncSession, principal: Principal, node_id: str) -> Node:
    if principal.role not in (Role.system_admin, Role.hoa_manager, Role.technician, Role.resident):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")
    node = await session.get(Node, node_id)
    if node is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "node not found")
    if principal.role == Role.resident:
        unit_id = await session.scalar(select(Zone.unit_id).where(Zone.id == node.zone_id))
        mine = await session.scalar(
            select(ResidentUnit.id).where(ResidentUnit.user_id == principal.user_id, ResidentUnit.unit_id == unit_id)
            .limit(1)
        )
        if unit_id is None or mine is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "node not found")
    elif not manages(await managed_buildings(session, principal), node.building_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "node not found")
    return node


@router.post("/nodes/{node_id}/commands", response_model=CommandSentOut, status_code=status.HTTP_202_ACCEPTED)
async def send_command(
    node_id: str,
    req: CommandIn,
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> CommandSentOut:
    """Publish a hardware command to the node; the result
    arrives on `<base>/command/result` (WebSocket `command_result`, GET .../commands)."""
    detector_setting = req.command in ("DETECTOR_ON", "DETECTOR_OFF")
    if detector_setting and principal.role not in (Role.system_admin, Role.hoa_manager, Role.technician):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")
    node = await _commandable_node(session, principal, node_id)
    valid = NODE_COMMANDS.get(node.kind, {})
    if req.command not in valid:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            f"{req.command} is not a {node.kind} node command; use {', '.join(valid)}")
    if detector_setting:
        detector = (node.last_status or {}).get("gas_detector")
        if not isinstance(detector, dict) or not isinstance(detector.get("enabled"), bool):
            raise HTTPException(status.HTTP_409_CONFLICT,
                                "node firmware does not support gas detector configuration; update firmware first")
    if not node.online:
        raise HTTPException(status.HTTP_409_CONFLICT, "node is offline")
    if await commands.too_soon(session, node.id):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "wait 3 s between commands to the same node")
    try:
        row = await commands.send(session, node, req.command, principal.user_id)
    except broker.BrokerUnavailable as exc:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from exc
    return CommandSentOut(command_id=row.id, node_id=node.id, command=row.command, status=row.status,
                          sent_ts=row.sent_ts)


@router.get("/nodes/{node_id}/commands", response_model=list[CommandOut])
async def list_commands(
    node_id: str,
    limit: int = Query(default=20, ge=1, le=100),
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> list[CommandOut]:
    node = await _commandable_node(session, principal, node_id)
    rows = (
        await session.scalars(
            select(DeviceCommand).where(DeviceCommand.node_id == node.id)
            .order_by(DeviceCommand.sent_ts.desc(), DeviceCommand.id.desc()).limit(limit)
        )
    ).all()
    # residents see who sent a command only for their own (like the summary's last_command)
    return await commands.outs(session, rows, viewer_id=principal.user_id if principal.role == Role.resident else None)
