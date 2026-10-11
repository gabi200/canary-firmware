"""Staff scope: which buildings a principal may administer.

system_admin: every building. hoa_manager and technician: the buildings in `staff_buildings`,
or every building when they have none (legacy single-building hubs). Anyone else: none.
"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import Role
from app.models import StaffBuilding
from app.security import Principal


async def managed_buildings(session: AsyncSession, principal: Principal) -> set[str] | None:
    """None = every building; a set = only those (empty: none)."""
    if principal.role == Role.system_admin:
        return None
    if principal.role in (Role.hoa_manager, Role.technician):
        rows = await session.scalars(
            select(StaffBuilding.building_id).where(StaffBuilding.user_id == principal.user_id))
        return set(rows.all()) or None
    return set()


def manages(buildings: set[str] | None, building_id: str | None) -> bool:
    return buildings is None or building_id in buildings
