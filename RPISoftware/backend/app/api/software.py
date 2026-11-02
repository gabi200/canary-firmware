"""Hub software: GitHub's newest commits, each Pi's version, and updates (app.software)."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app import cluster, software
from app.config import settings
from app.db import get_session
from app.enums import Role
from app.models import AuditLogEntry
from app.security import Principal, require_roles

router = APIRouter(prefix="/api/v1/hub/software", tags=["hub"])
staff = require_roles(Role.hoa_manager, Role.technician)


class UpdateIn(BaseModel):
    scope: str  # "all" or one Pi: processing | web | ai ("hub" on a one-Pi hub)
    commit: str


class DismissIn(BaseModel):
    name: str


def _host(name: str) -> str:
    hosts = software.helper_hosts()
    if name not in hosts:
        raise HTTPException(422, f"unknown Pi {name!r}")
    return hosts[name]


def _configured() -> None:
    if not settings.updater_key:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "updater key not configured")


async def _relay(name: str, path: str, body: dict | None, ok: int, timeout: float = 5.0) -> None:
    code, answer = await software.call(_host(name), "POST", path, body, timeout=timeout)
    if code == 0:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, f"the {name} Pi's updater does not answer")
    if code != ok:
        raise HTTPException(code if code in (409, 422) else status.HTTP_502_BAD_GATEWAY,
                            answer.get("error") or f"the {name} Pi's updater answered {code}")


@router.get("")
async def software_status(_: Principal = Depends(staff)) -> dict:
    return await software.overview()


@router.post("/fetch")
async def software_fetch(_: Principal = Depends(staff)) -> dict:
    _configured()
    await asyncio.gather(*(software.call(ip, "POST", "/fetch", timeout=30) for ip in software.helper_hosts().values()))
    return await software.overview()


@router.post("/update")
async def software_update(
    req: UpdateIn,
    principal: Principal = Depends(staff),
    session: AsyncSession = Depends(get_session),
) -> dict:
    if not software.SHA_RE.match(req.commit):
        raise HTTPException(422, "commit must be a 40-character hex id")
    if req.scope != "all":
        _host(req.scope)
    _configured()
    if req.scope == "all":
        await _relay(cluster.node_name(), "/rollout", {"commit": req.commit}, 202)
    else:
        await _relay(req.scope, "/update", {"commit": req.commit}, 202)
    session.add(AuditLogEntry(actor=principal.user_id, action="software_update", target=req.scope,
                              detail={"commit": req.commit}))
    await session.commit()
    return await software.overview()


@router.post("/dismiss")
async def software_dismiss(req: DismissIn, _: Principal = Depends(staff)) -> dict:
    _host(req.name)
    _configured()
    await _relay(req.name, "/dismiss", None, 200)
    return await software.overview()
