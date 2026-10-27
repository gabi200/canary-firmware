"""Water-leak impact map (app.analytics.water_impact): managers and dispatchers, as the incident's
accounting. Read-only; it never touches the incident or the valve."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics import water_impact
from app.config import settings
from app.db import get_session
from app.enums import HazardType, Role
from app.models import Incident, Unit, Zone
from app.schemas import WaterImpactOut, WaterImpactUnitOut
from app.security import Principal, require_roles

router = APIRouter(prefix="/api/v1", tags=["incidents"])


@router.get("/incidents/{incident_id}/water-impact", response_model=WaterImpactOut)
async def get_water_impact(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> WaterImpactOut:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    state, topology = water_impact.load_topology(settings.water_topology_file)
    if incident.hazard_type != HazardType.water_leak.value:
        return WaterImpactOut(incident_id=incident_id, applicable=False, topology=state, leaking_units=[], affected=[])
    zone_ids = {z for z in [incident.primary_zone_id, *(incident.affected_zone_ids or [])] if z}
    leaking = set((await session.scalars(select(Zone.unit_id).where(Zone.id.in_(zone_ids)))).all())
    building = topology.get(incident.building_id)
    if state == water_impact.CONFIGURED and building is None:
        state = water_impact.NOT_CONFIGURED  # the file has no entry for this building
    impacts = water_impact.affected_units(building, leaking) if building else []
    labels = dict((await session.execute(
        select(Unit.id, Unit.label).where(Unit.id.in_(leaking | {i.unit_id for i in impacts})))).all())
    return WaterImpactOut(
        incident_id=incident_id, applicable=True, topology=state,
        leaking_units=[WaterImpactUnitOut(unit_id=u, label=labels.get(u, u), reason="leak", hops=0, via_unit_id=u)
                       for u in sorted(leaking)],
        affected=[WaterImpactUnitOut(unit_id=i.unit_id, label=labels.get(i.unit_id, i.unit_id), reason=i.reason,
                                     hops=i.hops, via_unit_id=i.via_unit_id, riser=i.riser) for i in impacts],
    )
