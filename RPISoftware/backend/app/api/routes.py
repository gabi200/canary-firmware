"""REST + WebSocket endpoints (ARCHITECTURE.md section A.5)."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.service import AnalyticsService
from app.db import get_session
from app.enums import OPEN_INCIDENT_STATES, Role
from app.incidents.service import IncidentService
from app.models import (
    AssemblyPoint,
    Building,
    CheckIn,
    Device,
    EvacuationRoute,
    Incident,
    IncidentEvent,
    ResidentUnit,
    SensorReading,
    User,
    Zone,
)
from app.notify.service import NotificationService
from app.occupancy.service import OccupancyService
from app.realtime.ws import manager
from app.schemas import (
    AccountingOut,
    AssemblyPointOut,
    BuildingOut,
    CheckInOut,
    CheckInRequest,
    DeviceOut,
    EvacuationOut,
    EvacuationRouteOut,
    IncidentEventOut,
    IncidentOut,
    IngestResult,
    ReadingOut,
    ResidentOut,
    RosterEntry,
    RosterOut,
    TelemetryPayload,
    Token,
    TokenRequest,
    TriangulationContributor,
    TriangulationOut,
    ZoneOccupancy,
    ZoneOut,
)
from app.security import Principal, create_access_token, decode_token, get_current_principal, require_roles

router = APIRouter(prefix="/api/v1")


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
@router.post("/auth/token", response_model=Token, tags=["auth"])
async def issue_token(req: TokenRequest, session: AsyncSession = Depends(get_session)) -> Token:
    """Dev token issuance by username (no password in MVP). Swap for real auth later."""
    user = await session.scalar(select(User).where(User.username == req.username))
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown user")
    token = create_access_token(user.id, user.username, user.role)
    return Token(access_token=token, role=user.role, user_id=user.id)


# --------------------------------------------------------------------------- #
# Buildings / devices
# --------------------------------------------------------------------------- #
@router.get("/buildings", response_model=list[BuildingOut], tags=["buildings"])
async def list_buildings(
    _: Principal = Depends(get_current_principal), session: AsyncSession = Depends(get_session)
) -> list[Building]:
    return list((await session.scalars(select(Building))).all())


@router.get("/buildings/{building_id}", response_model=BuildingOut, tags=["buildings"])
async def get_building(
    building_id: str,
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> Building:
    building = await session.get(Building, building_id)
    if building is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    return building


@router.get("/buildings/{building_id}/devices", response_model=list[DeviceOut], tags=["buildings"])
async def list_devices(
    building_id: str,
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> list[Device]:
    return list(
        (await session.scalars(select(Device).where(Device.building_id == building_id))).all()
    )


@router.get("/buildings/{building_id}/zones", response_model=list[ZoneOut], tags=["buildings"])
async def list_zones(
    building_id: str,
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> list[Zone]:
    return list((await session.scalars(select(Zone).where(Zone.building_id == building_id))).all())


@router.get("/buildings/{building_id}/readings", response_model=list[ReadingOut], tags=["telemetry"])
async def list_readings(
    building_id: str,
    sensor_type: str | None = Query(default=None),
    limit: int = Query(default=200, le=2000),
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> list[SensorReading]:
    q = select(SensorReading).where(SensorReading.building_id == building_id)
    if sensor_type:
        q = q.where(SensorReading.sensor_type == sensor_type)
    q = q.order_by(SensorReading.ts.desc()).limit(limit)
    return list((await session.scalars(q)).all())


@router.get("/buildings/{building_id}/evacuation", response_model=EvacuationOut, tags=["buildings"])
async def building_evacuation(
    building_id: str,
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> EvacuationOut:
    routes = (
        await session.scalars(select(EvacuationRoute).where(EvacuationRoute.building_id == building_id))
    ).all()
    points = (
        await session.scalars(select(AssemblyPoint).where(AssemblyPoint.building_id == building_id))
    ).all()
    return EvacuationOut(
        building_id=building_id,
        routes=[EvacuationRouteOut.model_validate(r) for r in routes],
        assembly_points=[AssemblyPointOut.model_validate(p) for p in points],
    )


@router.get("/buildings/{building_id}/occupancy", tags=["occupancy"])
async def building_occupancy(
    building_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> dict:
    per_zone = await OccupancyService(session).latest_per_zone(building_id)
    return {
        "building_id": building_id,
        "zones": [ZoneOccupancy(zone_id=z, persons_est=n).model_dump() for z, n in per_zone.items()],
        "total": round(sum(per_zone.values()), 2),
    }


@router.get("/buildings/{building_id}/residents", response_model=list[ResidentOut], tags=["occupancy"])
async def building_residents(
    building_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> list[ResidentOut]:
    """The named residents registered to this building (identity-sensitive — managers/dispatchers)."""
    people = await OccupancyService(session).building_residents(building_id)
    return [
        ResidentOut(
            user_id=p.user_id,
            display_name=p.display_name,
            unit_id=p.unit_id,
            unit_label=p.unit_label,
            phone=p.phone,
        )
        for p in people
    ]


# --------------------------------------------------------------------------- #
# Incidents
# --------------------------------------------------------------------------- #
@router.get("/buildings/{building_id}/incidents", response_model=list[IncidentOut], tags=["incidents"])
async def list_incidents(
    building_id: str,
    active: bool = Query(default=False),
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> list[Incident]:
    q = select(Incident).where(Incident.building_id == building_id)
    if active:
        q = q.where(Incident.state.in_([s.value for s in OPEN_INCIDENT_STATES]))
    q = q.order_by(Incident.opened_ts.desc())
    return list((await session.scalars(q)).all())


@router.get("/incidents/{incident_id}", response_model=IncidentOut, tags=["incidents"])
async def get_incident(
    incident_id: str,
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> Incident:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    return incident


@router.get("/incidents/{incident_id}/events", response_model=list[IncidentEventOut], tags=["incidents"])
async def incident_events(
    incident_id: str,
    _: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> list[IncidentEvent]:
    return list(
        (
            await session.scalars(
                select(IncidentEvent)
                .where(IncidentEvent.incident_id == incident_id)
                .order_by(IncidentEvent.ts.asc())
            )
        ).all()
    )


@router.get("/incidents/{incident_id}/accounting", response_model=AccountingOut, tags=["incidents"])
async def incident_accounting(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> AccountingOut:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    acc = await OccupancyService(session).accounting(incident_id, incident.building_id)
    return AccountingOut(
        incident_id=acc.incident_id,
        occupancy_total=acc.occupancy_total,
        accounted=acc.accounted,
        unaccounted=acc.unaccounted,
        needs_help=acc.needs_help,
        zones_with_people=[ZoneOccupancy(zone_id=z, persons_est=n) for z, n in acc.zones_with_people],
    )


@router.get("/incidents/{incident_id}/roster", response_model=RosterOut, tags=["incidents"])
async def incident_roster(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> RosterOut:
    """Named residents + their live check-in status for an incident: who is safe, who needs
    help, who is still unaccounted. The actionable detail behind the accounting counts."""
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")

    svc = OccupancyService(session)
    people = await svc.roster(incident_id, incident.building_id)
    safe, needs_help, awaiting = svc.roster_summary(people)
    return RosterOut(
        incident_id=incident_id,
        total=len(people),
        safe=safe,
        needs_help=needs_help,
        awaiting=awaiting,
        entries=[
            RosterEntry(
                user_id=p.user_id,
                display_name=p.display_name,
                unit_id=p.unit_id,
                unit_label=p.unit_label,
                phone=p.phone,
                status=p.status,
                source=p.source,
                ts=p.ts,
            )
            for p in people
        ],
    )


@router.get("/incidents/{incident_id}/triangulation", response_model=TriangulationOut, tags=["incidents"])
async def incident_triangulation(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> TriangulationOut:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")

    result = await AnalyticsService(session).triangulate_incident(incident)
    await session.commit()

    if result is not None:
        return TriangulationOut(
            incident_id=incident_id,
            source_zone_id=result.source_zone_id,
            source_x=result.source_x,
            source_y=result.source_y,
            confidence=result.confidence,
            method=result.method,
            n_contributors=result.n_contributors,
            airflow_applied=result.airflow_applied,
            contributors=[
                TriangulationContributor(
                    device_id=c.device_id, zone_id=c.zone_id, value=c.value, weight=c.weight
                )
                for c in result.contributors
            ],
        )

    # fall back to the last persisted estimate
    detail = incident.triangulation_detail or {}
    return TriangulationOut(
        incident_id=incident_id,
        source_zone_id=incident.est_source_zone_id,
        source_x=incident.est_source_x,
        source_y=incident.est_source_y,
        confidence=incident.triangulation_confidence or 0.0,
        method=incident.triangulation_method or "none",
        n_contributors=detail.get("n_contributors", 0),
        airflow_applied=detail.get("airflow_applied", False),
        contributors=[TriangulationContributor(**c) for c in detail.get("contributors", [])],
    )


@router.post("/incidents/{incident_id}/checkin", response_model=CheckInOut, tags=["incidents"])
async def check_in(
    incident_id: str,
    req: CheckInRequest,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> CheckIn:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")

    unit_id = req.unit_id
    if unit_id is None:
        ru = await session.scalar(select(ResidentUnit).where(ResidentUnit.user_id == principal.user_id))
        unit_id = ru.unit_id if ru else None

    checkin = CheckIn(
        incident_id=incident_id,
        user_id=principal.user_id,
        unit_id=unit_id,
        status=req.status.value,
        source=req.source.value,
    )
    session.add(checkin)
    await session.commit()
    await session.refresh(checkin)
    await NotificationService(session).on_checkin(incident, checkin)
    return checkin


@router.post("/incidents/{incident_id}/dismiss", response_model=IncidentOut, tags=["incidents"])
async def dismiss_incident(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> Incident:
    try:
        incident = await IncidentService(session).dismiss(incident_id, actor=principal.username)
    except ValueError as exc:
        # Illegal state transition (e.g. dismissing an already-evacuating incident) is a
        # conflict, not a server error — return 409 so the dashboard shows a clear message.
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    await session.commit()
    return incident


@router.post("/incidents/{incident_id}/order-evacuation", response_model=IncidentOut, tags=["incidents"])
async def order_evacuation(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> Incident:
    try:
        incident = await IncidentService(session).order_evacuation(incident_id, actor=principal.username)
    except ValueError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    await session.commit()
    return incident


@router.post("/incidents/{incident_id}/resolve", response_model=IncidentOut, tags=["incidents"])
async def resolve_incident(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> Incident:
    try:
        incident = await IncidentService(session).resolve(incident_id, actor=principal.username)
    except ValueError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    await session.commit()
    return incident


# --------------------------------------------------------------------------- #
# Telemetry HTTP ingress (dev/testing; the production path is MQTT)
# --------------------------------------------------------------------------- #
@router.post("/telemetry", response_model=IngestResult, tags=["ingest"])
async def post_telemetry(
    payload: TelemetryPayload, session: AsyncSession = Depends(get_session)
) -> IngestResult:
    """HTTP telemetry ingress for testing without a broker. Mirrors the MQTT path
    exactly (same pipeline). In production, devices publish over MQTT, not here."""
    from app.ingestion.pipeline import ingest_telemetry

    return await ingest_telemetry(session, payload)


# --------------------------------------------------------------------------- #
# WebSocket: live incident / reading / check-in stream per building
# --------------------------------------------------------------------------- #
@router.websocket("/ws/incidents")
async def ws_incidents(ws: WebSocket, building_id: str = Query(...), token: str = Query(...)) -> None:
    try:
        decode_token(token)  # authenticate before accepting
    except HTTPException:
        await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        return
    await manager.connect(building_id, ws)
    try:
        while True:
            # We don't expect client messages; this keeps the socket open.
            await ws.receive_text()
    except WebSocketDisconnect:
        await manager.disconnect(building_id, ws)
