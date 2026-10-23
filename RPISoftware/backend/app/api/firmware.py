"""Firmware API (app.firmware): node versions, push targets and pushes to a node's /api/ota.

Reads: system_admin, hoa_manager and technician, in their buildings. Pinning a target and pushing
firmware: system_admin and technician. Out-of-scope ids answer 404; every change is audited
without the token.
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, File, HTTPException, Response, UploadFile, status
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import firmware
from app.api.admin import Scope, _building, staff_scope
from app.care.service import CareUnavailable
from app.db import get_session
from app.enums import Role
from app.models import AuditLogEntry, FirmwareUpdate, Node, NodeFirmwareSeen, NodeOtaTarget
from app.schemas import FirmwareSeenOut, FirmwareUpdateOut, NodeFirmwareDetailOut, NodeFirmwareOut, OtaTargetIn

router = APIRouter(prefix="/api/v1/admin", tags=["firmware"])

_NO_KEY = "firmware pushes need CANARY_CARE_KEY to keep device tokens encrypted (run scripts/pi_setup.sh)"


def _maintainer(scope: Scope) -> None:
    if scope.principal.role not in (Role.system_admin, Role.technician):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")


async def _node(session: AsyncSession, scope: Scope, node_id: str) -> Node:
    node = await session.get(Node, node_id)
    scope.check(node.building_id if node else None, "node")
    return node


async def _last_updates(session: AsyncSession, node_ids: list[str]) -> dict[str, FirmwareUpdate]:
    if not node_ids:
        return {}
    newest = (
        select(FirmwareUpdate.node_id, func.max(FirmwareUpdate.created_ts).label("ts"))
        .where(FirmwareUpdate.node_id.in_(node_ids)).group_by(FirmwareUpdate.node_id).subquery()
    )
    rows = await session.scalars(select(FirmwareUpdate).join(
        newest, (FirmwareUpdate.node_id == newest.c.node_id) & (FirmwareUpdate.created_ts == newest.c.ts)))
    return {j.node_id: j for j in rows.all()}


async def _outs(session: AsyncSession, nodes: list[Node]) -> list[NodeFirmwareOut]:
    ids = [n.id for n in nodes]
    targets = {t.node_id: t for t in await session.scalars(select(NodeOtaTarget).where(NodeOtaTarget.node_id.in_(ids)))}
    last = await _last_updates(session, ids)
    last_outs = {o.node_id: o for o in await firmware.outs(session, list(last.values()))}
    now = datetime.now(timezone.utc)
    return [
        NodeFirmwareOut(
            node_id=n.id, name=n.name, kind=n.kind, zone_id=n.zone_id, online=n.online, firmware=n.firmware,
            reported_ip=firmware.reported_ip(n), address=targets[n.id].address if n.id in targets else None,
            token_set=n.id in targets, blocked=firmware.blocked(n, targets.get(n.id), last.get(n.id), now),
            last_update=last_outs.get(n.id),
        )
        for n in nodes
    ]


@router.get("/buildings/{building_id}/firmware", response_model=list[NodeFirmwareOut])
async def list_firmware(
    building_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> list[NodeFirmwareOut]:
    """Every node of the building with its firmware version and whether a push can go to it."""
    await _building(session, scope, building_id)
    nodes = await session.scalars(select(Node).where(Node.building_id == building_id).order_by(Node.name, Node.id))
    return await _outs(session, list(nodes.all()))


@router.get("/nodes/{node_id}/firmware", response_model=NodeFirmwareDetailOut)
async def node_firmware(
    node_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> NodeFirmwareDetailOut:
    """One node's firmware plus the versions it reported over time and its last 20 pushes."""
    node = await _node(session, scope, node_id)
    [out] = await _outs(session, [node])
    seen = await session.scalars(select(NodeFirmwareSeen).where(NodeFirmwareSeen.node_id == node.id)
                                 .order_by(NodeFirmwareSeen.ts.desc(), NodeFirmwareSeen.id.desc()).limit(50))
    jobs = await session.scalars(select(FirmwareUpdate).where(FirmwareUpdate.node_id == node.id)
                                 .order_by(FirmwareUpdate.created_ts.desc()).limit(20))
    return NodeFirmwareDetailOut(
        **out.model_dump(),
        history=[FirmwareSeenOut(firmware=s.firmware, ts=s.ts) for s in seen.all()],
        updates=await firmware.outs(session, list(jobs.all())),
    )


@router.put("/nodes/{node_id}/ota-target", response_model=NodeFirmwareOut)
async def set_target(
    node_id: str, req: OtaTargetIn, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> NodeFirmwareOut:
    """Pin the device's HTTP address and store its API token (sealed; never returned)."""
    _maintainer(scope)
    node = await _node(session, scope, node_id)
    target = await session.get(NodeOtaTarget, node.id)
    if req.token is None and target is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "token is required for a new target")
    target = target or NodeOtaTarget(node_id=node.id)
    if req.token is not None:
        try:
            target.token_enc = firmware.seal_token(req.token)
        except CareUnavailable as exc:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, _NO_KEY) from exc
    target.address, target.updated_ts = req.address, datetime.now(timezone.utc)
    session.add(target)
    session.add(scope.audit("ota_target_set", node.id, ["address", "token"] if req.token is not None else ["address"]))
    await session.commit()
    return (await _outs(session, [node]))[0]


@router.delete("/nodes/{node_id}/ota-target", status_code=status.HTTP_204_NO_CONTENT)
async def clear_target(
    node_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> Response:
    _maintainer(scope)
    node = await _node(session, scope, node_id)
    await session.execute(delete(NodeOtaTarget).where(NodeOtaTarget.node_id == node.id))
    session.add(scope.audit("ota_target_cleared", node.id, []))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/nodes/{node_id}/firmware", response_model=FirmwareUpdateOut, status_code=status.HTTP_202_ACCEPTED)
async def push_firmware(
    node_id: str,
    background: BackgroundTasks,
    image: UploadFile = File(..., alias="firmware"),
    scope: Scope = Depends(staff_scope),
    session: AsyncSession = Depends(get_session),
) -> FirmwareUpdateOut:
    """Queue the uploaded .bin for the node. 409 while it is offline, has no pinned target, is
    updating or has a push pending; progress arrives as WebSocket `firmware_update` events."""
    _maintainer(scope)
    node = await _node(session, scope, node_id)
    data = await image.read(firmware.MAX_IMAGE_BYTES + 1)
    if len(data) > firmware.MAX_IMAGE_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "firmware image is larger than 4 MiB")
    try:
        firmware.check_image(node.kind, data)
    except firmware.ImageRejected as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(exc)) from exc
    target = await session.get(NodeOtaTarget, node.id)
    last = (await _last_updates(session, [node.id])).get(node.id)
    reason = firmware.blocked(node, target, last, datetime.now(timezone.utc))
    if reason is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, reason)
    job = FirmwareUpdate(
        node_id=node.id, building_id=node.building_id, filename=firmware.safe_filename(image.filename),
        size=len(data), sha256=hashlib.sha256(data).hexdigest(), firmware_before=node.firmware,
        status="queued", requested_by_user_id=scope.principal.user_id,
    )
    session.add(job)
    await session.flush()
    session.add(AuditLogEntry(actor=scope.principal.user_id, action="firmware_push", target=node.id,
                              detail={"update_id": job.id, "sha256": job.sha256, "size": job.size}))
    await session.commit()
    background.add_task(firmware.run, job.id, data)
    return (await firmware.outs(session, [job]))[0]
