"""Hub-wide demo/real mode: read by every signed-in user, switched by staff managers."""

from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app import mode
from app.db import get_session
from app.enums import Role
from app.schemas import ModeIn, ModeOut
from app.security import Principal, get_current_principal, require_roles

router = APIRouter(prefix="/api/v1/mode", tags=["hub"])


async def _out(session: AsyncSession) -> ModeOut:
    current = await mode.get_mode(session)
    return ModeOut(mode=current, building_id=mode.building_for(current),
                   live_alarm=await mode.live_alarm(session))


@router.get("", response_model=ModeOut)
async def read_mode(_: Principal = Depends(get_current_principal),
                    session: AsyncSession = Depends(get_session)) -> ModeOut:
    return await _out(session)


@router.put("", response_model=ModeOut)
async def switch_mode(body: ModeIn, principal: Principal = Depends(require_roles(Role.hoa_manager)),
                      session: AsyncSession = Depends(get_session)) -> ModeOut:
    await mode.set_mode(session, body.mode, principal.user_id)
    return await _out(session)
