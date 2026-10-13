"""Cluster status for the dashboard, and the node-to-node endpoints of three-Pi mode (app.cluster).

`/internal/...` is not proxied by nginx and answers 404 unless the caller presents the shared
CANARY_CLUSTER_SECRET (port 8000 is reachable on the LAN), so it also stays 404 in single mode.
"""

from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app import cluster
from app.db import get_session
from app.enums import Role
from app.realtime.ws import manager
from app.security import Principal, require_roles

router = APIRouter(tags=["cluster"])


@router.get("/api/v1/cluster")
async def cluster_status(
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.technician)),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Which Pi runs what (three-Pi mode), or the single hub."""
    return await cluster.status(session)


def _peer(key: str | None = Header(default=None, alias=cluster.KEY_HEADER)) -> None:
    if not cluster.key_ok(key):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not Found")


async def _object(request: Request) -> dict[str, Any]:
    """The JSON object body, read only after _peer let the caller in (a body model would be
    validated first, and a 422 would tell anyone that the endpoint exists)."""
    try:
        body = json.loads(await request.body())
    except ValueError:
        body = None
    if not isinstance(body, dict):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "a JSON object is required")
    return body


@router.post("/internal/cluster/broadcast", include_in_schema=False, dependencies=[Depends(_peer)])
async def peer_broadcast(request: Request) -> dict:
    body = await _object(request)
    building_id, message = body.get("building_id"), body.get("message")
    if not isinstance(building_id, str) or not isinstance(message, dict):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "building_id and message are required")
    await manager.send_local(building_id, message)
    return {}


@router.post("/internal/ai/{task}", include_in_schema=False, dependencies=[Depends(_peer)])
async def peer_ai(task: str, request: Request) -> dict:
    from app.ai.offload import run_local  # deferred: app.ai imports analytics

    payload = await _object(request)
    try:
        return await run_local(task, payload)
    except KeyError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unknown task") from exc
