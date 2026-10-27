"""Motion evidence from ESPectre Wi-Fi boards (app.analytics.motion), staff only: system_admin,
hoa_manager and technician, in their buildings. Out-of-scope or unknown buildings answer 404."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.motion import building_motion
from app.api.admin import Scope, staff_scope
from app.db import get_session
from app.models import Building
from app.schemas import BuildingMotionOut, MotionSensorOut, ZoneMotionOut

router = APIRouter(prefix="/api/v1", tags=["motion"])


@router.get("/buildings/{building_id}/motion", response_model=BuildingMotionOut)
async def get_building_motion(
    building_id: str,
    scope: Scope = Depends(staff_scope),
    session: AsyncSession = Depends(get_session),
) -> BuildingMotionOut:
    scope.check(building_id, "building")
    if await session.get(Building, building_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    zones, unmapped = await building_motion(session, building_id)
    return BuildingMotionOut(
        building_id=building_id,
        zones=[ZoneMotionOut.model_validate(z) for z in zones],
        unmapped=[MotionSensorOut.model_validate(s) for s in unmapped],
    )
