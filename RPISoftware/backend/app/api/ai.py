"""AI endpoints: the incident brief for responders (app.ai.brief, docs/AI_IDEAS.md).

The facts are read here, on the node that serves the request; the text is written where
app.ai.offload sends the "brief" task: the AI node's LLM in three-Pi mode, this node otherwise, and
a template wherever there is no LLM. Same roles and 404s as the incident accounting endpoint.
"""

from __future__ import annotations

from datetime import datetime, timezone, tzinfo
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai import offload
from app.analytics.service import AnalyticsService
from app.db import get_session
from app.enums import Role
from app.i18n import current_language
from app.models import Building, Incident, IncidentEvent, Unit, Zone
from app.occupancy.service import OccupancyService
from app.schemas import IncidentBriefOut
from app.security import Principal, require_roles

router = APIRouter(prefix="/api/v1", tags=["ai"])

TIMELINE_EVENTS = 8  # the brief's view of the incident history: its last transitions


def _time_zone(name: str | None) -> tzinfo:
    try:
        return ZoneInfo(name) if name else timezone.utc
    except (KeyError, ValueError):  # unknown name, or no tz database in the image
        return timezone.utc


def _clock(ts: datetime, tz: tzinfo) -> str:
    """Building-local "HH:MM", with the date when it is not today."""
    local = (ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)).astimezone(tz)
    return local.strftime("%H:%M" if local.date() == datetime.now(tz).date() else "%Y-%m-%d %H:%M")


async def _facts(session: AsyncSession, incident: Incident) -> dict:
    """What the brief may say: labels, counts and the recent timeline. No names, notes, phone
    numbers or care data, since dispatchers read the brief (app.ai.brief)."""
    building = await session.get(Building, incident.building_id)
    tz = _time_zone(building.timezone if building is not None else None)
    zone_ids = [z for z in (incident.primary_zone_id, incident.est_source_zone_id) if z]
    rows = await session.execute(
        select(Zone.id, Zone.label, Unit.label).join(Unit, Unit.id == Zone.unit_id, isouter=True)
        .where(Zone.id.in_(zone_ids))
    )
    places = {zone_id: f"{zone or zone_id} ({unit})" if unit else zone or zone_id for zone_id, zone, unit in rows}
    signature = (await AnalyticsService(session).latest_signatures([incident.id])).get(incident.id)
    acc = await OccupancyService(session).accounting(incident.id, incident.building_id)
    events = (await session.scalars(
        select(IncidentEvent).where(IncidentEvent.incident_id == incident.id)
        .order_by(IncidentEvent.ts.desc()).limit(TIMELINE_EVENTS)
    )).all()
    source = incident.est_source_zone_id
    return {
        "hazard": incident.hazard_type,
        "state": incident.state,
        "severity": incident.severity,
        "opened": _clock(incident.opened_ts, tz),
        "zone": places.get(incident.primary_zone_id, incident.primary_zone_id),
        "source_zone": places.get(source, source),
        "source_confidence": incident.triangulation_confidence if source else None,
        "signature": signature.label if signature is not None else None,
        "people": {
            "present_estimate": round(acc.occupancy_total),
            "confirmed_safe": acc.accounted,
            "need_help": acc.needs_help,
            "unaccounted": acc.unaccounted,
        },
        "timeline": [{"time": _clock(e.ts, tz), "state": e.to_state, "reason": e.reason} for e in reversed(events)],
    }


@router.get("/incidents/{incident_id}/brief", response_model=IncidentBriefOut)
async def incident_brief(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> IncidentBriefOut:
    """Two to four sentences for responders in the request's language (Accept-Language: ro | en),
    from database facts only. The hub's LLM (AI HAT+ 2) may take up to a minute; without one the
    template answers at once."""
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    facts = await _facts(session, incident)
    await session.close()  # hold no database connection while the LLM writes
    brief = await offload.write_brief(facts, current_language())
    return IncidentBriefOut(
        incident_id=incident_id,
        text=brief["text"],
        source=brief["source"],
        model=brief["model"],
        node=brief["node"],
        generated_ts=datetime.now(timezone.utc).replace(microsecond=0),
    )
