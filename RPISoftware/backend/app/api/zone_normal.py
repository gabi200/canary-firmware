"""Per-room learned normal (app.analytics.zone_normal): managers, dispatchers and technicians.
Read-only; the references are built by the processing node's hourly job, never here."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.zone_normal import building_normal
from app.db import get_session
from app.enums import Role
from app.models import Building
from app.schemas import BuildingNormalOut, ZoneNormalOut
from app.security import Principal, require_roles

router = APIRouter(prefix="/api/v1", tags=["analytics"])


@router.get("/buildings/{building_id}/zone-normal", response_model=BuildingNormalOut)
async def get_zone_normal(
    building_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external, Role.technician)),
    session: AsyncSession = Depends(get_session),
) -> BuildingNormalOut:
    if await session.get(Building, building_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    zones = await building_normal(session, building_id)
    return BuildingNormalOut(building_id=building_id, zones=[ZoneNormalOut.model_validate(z) for z in zones])
