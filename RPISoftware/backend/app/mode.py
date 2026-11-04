"""Hub-wide demo/real mode. The mode only picks which building the apps show; it never
suppresses, hides or delays incidents in the real building."""

from __future__ import annotations

from typing import Literal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.enums import ALARMED_STATES
from app.models import AuditLogEntry, HubSetting, Incident

Mode = Literal["demo", "real"]
_KEY = "mode"


async def get_mode(session: AsyncSession) -> Mode:
    row = await session.get(HubSetting, _KEY)
    return "demo" if row is not None and row.value == "demo" else "real"


async def set_mode(session: AsyncSession, mode: Mode, user_id: str) -> None:
    await session.merge(HubSetting(key=_KEY, value=mode, updated_by=user_id))
    session.add(AuditLogEntry(actor=user_id, action="set_mode", target=mode, detail={"mode": mode}))
    await session.commit()


def building_for(mode: Mode) -> str:
    return settings.demo_building_id if mode == "demo" else settings.live_building_id


async def live_alarm(session: AsyncSession) -> bool:
    found = await session.scalar(
        select(Incident.id)
        .where(Incident.building_id == settings.live_building_id,
               Incident.state.in_([s.value for s in ALARMED_STATES]))
        .limit(1)
    )
    return found is not None
