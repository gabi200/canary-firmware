"""REST + WebSocket endpoints (ARCHITECTURE.md section A.5)."""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, WebSocket, WebSocketDisconnect, status
from sqlalchemy import delete, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.nodes import NodeService, broadcast_node, parse_fields
from app import commands
from app.analytics.service import AnalyticsService
from app.care import service as care
from app.db import SessionLocal, get_session
from app.enums import HAZARD_SENSOR_TYPES, OCCUPANCY_SENSOR_TYPES, OPEN_INCIDENT_STATES, Role
from app.i18n import DEFAULT_USER_LANGUAGE
from app.incidents.service import IncidentService
from app.models import (
    AssemblyPoint,
    AuditLogEntry,
    Building,
    CareCheckIn,
    CareProfile,
    CheckIn,
    Device,
    EscalationDelivery,
    EvacuationRoute,
    Floor,
    Incident,
    IncidentEvent,
    Node,
    NodeInbox,
    ResidentLocation,
    ResidentUnit,
    SensorReading,
    TriangulationSnapshot,
    Unit,
    User,
    UserPref,
    UserStatus,
    Zone,
)
from app.notify.service import NotificationService
from app.occupancy.service import OccupancyService
from app.realtime.ws import manager
from app.schemas import (
    AccountingOut,
    AssemblyPointOut,
    BuildingOut,
    BuildingSummaryOut,
    CareCheckInRequest,
    CareProfileIn,
    CareProfileOut,
    CheckInOut,
    CheckInRequest,
    LocationIn,
    LocationOut,
    DeviceOut,
    EvacuationOut,
    EscalationOut,
    EvacuationRouteOut,
    FusionExplanationOut,
    IncidentEventOut,
    IncidentOut,
    IngestResult,
    MeOut,
    MeUnitOut,
    MeUpdate,
    NodeHistoryOut,
    NodeOut,
    NodeUpdate,
    ReadingOut,
    ResidentOut,
    RosterEntry,
    RosterOut,
    SensorTrustOut,
    SignatureOut,
    TelemetryPayload,
    Token,
    TokenRequest,
    TriangulationContributor,
    TriangulationHistoryOut,
    TriangulationOut,
    TriangulationSnapshotOut,
    WaypointOut,
    ZoneOccupancy,
    ZoneOut,
)
from app.security import Principal, create_access_token, decode_token, get_current_principal, require_roles

router = APIRouter(prefix="/api/v1")
logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------- #
# Resident scope: managers, dispatchers and admins see every building; a resident
# only the buildings they have a unit in. Out-of-scope reads get the same 404 as
# unknown ids, so other buildings' ids are not confirmed.
# --------------------------------------------------------------------------- #
async def _in_scope(session: AsyncSession, principal: Principal, building_id: str | None) -> bool:
    if principal.role != Role.resident:
        return True
    return await session.scalar(
        select(ResidentUnit.id)
        .where(ResidentUnit.user_id == principal.user_id, ResidentUnit.building_id == building_id)
        .limit(1)
    ) is not None


async def _open_incident(session: AsyncSession, building_id: str) -> bool:
    return await session.scalar(
        select(Incident.id)
        .where(Incident.building_id == building_id, Incident.state.in_([s.value for s in OPEN_INCIDENT_STATES]))
        .limit(1)
    ) is not None


async def building_reader(
    building_id: str,
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> Principal:
    """Any authenticated role; a resident only for their own building (404 otherwise)."""
    if not await _in_scope(session, principal, building_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    return principal


async def incident_reader(
    incident_id: str,
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> Principal:
    """Any authenticated role; a resident only for incidents of their own building (404 otherwise)."""
    if principal.role == Role.resident:
        building_id = await session.scalar(select(Incident.building_id).where(Incident.id == incident_id))
        if not await _in_scope(session, principal, building_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    return principal


async def _resident_zone_ids(session: AsyncSession, principal: Principal, building_id: str) -> set[str]:
    """Zones a resident sees in detail (summary nodes, history): those of their own units and
    the building's common units (`Unit.kind == "common"`, e.g. hallway, boiler room). Empty
    when they have no unit in the building."""
    own = (
        await session.scalars(
            select(ResidentUnit.unit_id).where(
                ResidentUnit.user_id == principal.user_id, ResidentUnit.building_id == building_id
            )
        )
    ).all()
    if not own:
        return set()
    zones = await session.scalars(
        select(Zone.id)
        .join(Unit, Unit.id == Zone.unit_id)
        .where(Zone.building_id == building_id, or_(Unit.id.in_(own), Unit.kind == "common"))
    )
    return set(zones.all())


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
@router.post("/auth/token", response_model=Token, tags=["auth"])
async def issue_token(req: TokenRequest, session: AsyncSession = Depends(get_session)) -> Token:
    """Dev token issuance by username (no password in MVP). Swap for real auth later."""
    user = await session.scalar(select(User).where(User.username == req.username))
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "unknown user")
    account = await session.get(UserStatus, user.id)
    if account is not None and not account.active:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "account disabled")
    token = create_access_token(user.id, user.username, user.role)
    return Token(access_token=token, role=user.role, user_id=user.id)


# --------------------------------------------------------------------------- #
# Self-service account: any role reads and edits its own name and contact details
# --------------------------------------------------------------------------- #
async def _me(session: AsyncSession, principal: Principal) -> tuple[User, MeOut]:
    user = await session.get(User, principal.user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "user not found")
    rows = await session.execute(
        select(Unit, Floor.label)
        .join(ResidentUnit, ResidentUnit.unit_id == Unit.id)
        .join(Floor, Floor.id == Unit.floor_id, isouter=True)
        .where(ResidentUnit.user_id == user.id)
        .order_by(Unit.building_id, Unit.label, Unit.id)
    )
    units = [
        MeUnitOut(unit_id=u.id, unit_label=u.label, building_id=u.building_id, floor_label=floor, kind=u.kind)
        for u, floor in rows
    ]
    pref = await session.get(UserPref, user.id)
    return user, MeOut(user_id=user.id, username=user.username, display_name=user.display_name, role=user.role,
                       phone=user.phone, email=user.email, language=pref.language if pref else DEFAULT_USER_LANGUAGE,
                       units=units)


@router.get("/me", response_model=MeOut, tags=["auth"])
async def get_me(
    principal: Principal = Depends(get_current_principal), session: AsyncSession = Depends(get_session)
) -> MeOut:
    return (await _me(session, principal))[1]


@router.patch("/me", response_model=MeOut, tags=["auth"])
async def update_me(
    req: MeUpdate,
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> MeOut:
    """Edit display_name / phone (normalized to E.164) / email ("" clears phone or email) and the
    notification language. Audited as `account_updated` with the changed field names only."""
    user, me = await _me(session, principal)
    changed = [name for name, value in req.model_dump(exclude_unset=True).items() if getattr(me, name) != value]
    if changed:
        for name in changed:
            if name == "language":
                pref = await session.get(UserPref, user.id) or UserPref(user_id=user.id)
                pref.language = req.language
                session.add(pref)
            else:
                setattr(user, name, getattr(req, name))
        session.add(AuditLogEntry(actor=user.id, action="account_updated", target=user.id, detail={"fields": changed}))
        await session.commit()
    return (await _me(session, principal))[1]


# --------------------------------------------------------------------------- #
# Buildings / devices
# --------------------------------------------------------------------------- #
@router.get("/buildings", response_model=list[BuildingOut], tags=["buildings"])
async def list_buildings(
    principal: Principal = Depends(get_current_principal), session: AsyncSession = Depends(get_session)
) -> list[Building]:
    q = select(Building)
    if principal.role == Role.resident:
        q = q.where(Building.id.in_(select(ResidentUnit.building_id).where(ResidentUnit.user_id == principal.user_id)))
    return list((await session.scalars(q)).all())


@router.get("/buildings/{building_id}", response_model=BuildingOut, tags=["buildings"])
async def get_building(
    building_id: str,
    _: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> Building:
    building = await session.get(Building, building_id)
    if building is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    return building


@router.get("/buildings/{building_id}/devices", response_model=list[DeviceOut], tags=["buildings"])
async def list_devices(
    building_id: str,
    _: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> list[Device]:
    return list(
        (await session.scalars(select(Device).where(Device.building_id == building_id))).all()
    )


@router.get("/buildings/{building_id}/zones", response_model=list[ZoneOut], tags=["buildings"])
async def list_zones(
    building_id: str,
    _: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> list[ZoneOut]:
    rows = await session.execute(
        select(Zone, Unit.label, Floor.label)
        .join(Unit, Unit.id == Zone.unit_id, isouter=True)
        .join(Floor, Floor.id == Zone.floor_id, isouter=True)
        .where(Zone.building_id == building_id)
    )
    return [
        ZoneOut.model_validate(zone).model_copy(update={"unit_label": unit_label, "floor_label": floor_label})
        for zone, unit_label, floor_label in rows
    ]


@router.get("/buildings/{building_id}/readings", response_model=list[ReadingOut], tags=["telemetry"])
async def list_readings(
    building_id: str,
    sensor_type: str | None = Query(default=None),
    limit: int = Query(default=200, le=2000),
    principal: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> list[SensorReading]:
    q = select(SensorReading).where(SensorReading.building_id == building_id)
    if principal.role == Role.resident:  # hazard readings only: presence / occupancy is who is home
        q = q.where(SensorReading.sensor_type.in_([t.value for t in HAZARD_SENSOR_TYPES]))
    elif principal.role == Role.dispatcher_external and not await _open_incident(session, building_id):
        # dispatchers get raw presence only while an incident is open in the building
        q = q.where(SensorReading.sensor_type.not_in([t.value for t in OCCUPANCY_SENSOR_TYPES]))
    if sensor_type:
        q = q.where(SensorReading.sensor_type == sensor_type)
    q = q.order_by(SensorReading.ts.desc()).limit(limit)
    return list((await session.scalars(q)).all())


@router.get("/buildings/{building_id}/evacuation", response_model=EvacuationOut, tags=["buildings"])
async def building_evacuation(
    building_id: str,
    _: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> EvacuationOut:
    routes = (
        await session.scalars(
            select(EvacuationRoute)
            .where(EvacuationRoute.building_id == building_id)
            .order_by(EvacuationRoute.floor_id, EvacuationRoute.id)
        )
    ).all()
    points = (
        await session.scalars(
            select(AssemblyPoint)
            .where(AssemblyPoint.building_id == building_id)
            .order_by(AssemblyPoint.id)
        )
    ).all()
    zones = (await session.scalars(select(Zone).where(Zone.building_id == building_id))).all()
    zones_by_id = {zone.id: zone for zone in zones}
    points_by_id = {point.id: point for point in points}

    def humanize_waypoint_id(waypoint_id: str) -> str:
        return waypoint_id.replace("_", " ").capitalize() or "Waypoint"

    def route_out(route: EvacuationRoute) -> EvacuationRouteOut:
        path: list[str] = []
        waypoints: list[WaypointOut] = []
        for stored_waypoint in route.path or []:
            if isinstance(stored_waypoint, str):
                details = {}
                waypoint_id = stored_waypoint
            elif isinstance(stored_waypoint, dict):
                waypoint_id = stored_waypoint.get("id")
                if not isinstance(waypoint_id, str):
                    logger.warning(
                        "Skipping invalid waypoint in evacuation route %s: dict is missing a string id",
                        route.id,
                    )
                    continue
                details = stored_waypoint
            else:
                logger.warning(
                    "Skipping invalid waypoint in evacuation route %s: expected string or dict",
                    route.id,
                )
                continue
            path.append(waypoint_id)

            zone = zones_by_id.get(waypoint_id)
            point = points_by_id.get(waypoint_id)
            if zone is not None:
                label, kind = zone.label, zone.kind
            elif point is not None:
                label, kind = point.label, "assembly_point"
            else:
                label, kind = humanize_waypoint_id(waypoint_id), "waypoint"

            waypoints.append(
                WaypointOut(
                    id=waypoint_id,
                    label=details.get("label") or label or humanize_waypoint_id(waypoint_id),
                    kind=details.get("kind") or kind,
                    hint=details.get("hint") or "",
                )
            )

        return EvacuationRouteOut(
            id=route.id,
            building_id=route.building_id,
            floor_id=route.floor_id,
            from_zone_id=route.from_zone_id,
            to_assembly_point_id=route.to_assembly_point_id,
            label=route.label,
            path=path,
            waypoints=waypoints,
        )

    return EvacuationOut(
        building_id=building_id,
        routes=[route_out(route) for route in routes],
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
# Hardware nodes (docs/HARDWARE.md section 4)
# --------------------------------------------------------------------------- #
@router.get("/buildings/{building_id}/summary", response_model=BuildingSummaryOut, tags=["nodes"])
async def building_summary(
    building_id: str,
    principal: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> BuildingSummaryOut:
    """Analysis-only building status (residents: own building, own unit + common zones): no raw
    measurements."""
    if await session.get(Building, building_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    resident = principal.role == Role.resident
    # Residents: only what they may chart (own unit + common areas); an open incident anywhere
    # still sets their status and headline, so a neighbour's gas leak shows.
    zone_ids = await _resident_zone_ids(session, principal, building_id) if resident else None
    summary = await NodeService(session).building_summary(building_id, zone_ids)
    listed = [node for zone in summary.zones for node in zone.nodes]
    last = await commands.latest_per_node(session, [n.node_id for n in listed])
    items = dict(zip(last, await commands.outs(session, list(last.values()),
                                              viewer_id=principal.user_id if resident else None)))
    for node in listed:
        node.last_command = items.get(node.node_id)
    if resident:
        # Who is home stays with managers/dispatchers, like /occupancy.
        for zone in summary.zones:
            zone.occupied = None
            for node in zone.nodes:
                node.indicators = [i for i in node.indicators if i.key != "occupancy"]
    return summary


@router.get("/buildings/{building_id}/nodes", response_model=list[NodeOut], tags=["nodes"])
async def list_nodes(
    building_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external, Role.technician)),
    session: AsyncSession = Depends(get_session),
) -> list[NodeOut]:
    """Physical nodes with their latest raw status document + analysis (dashboard). Dispatchers
    never get the raw `presence` object (zone occupancy aggregates stay available)."""
    svc = NodeService(session)
    nodes = await svc.node_outs(await svc.building_nodes(building_id))
    last = await commands.latest_per_node(session, [n.id for n in nodes])
    items = dict(zip(last, await commands.outs(session, list(last.values()))))
    new = set((await session.scalars(
        select(NodeInbox.node_id).where(NodeInbox.node_id.in_([n.id for n in nodes])))).all())
    for node in nodes:
        node.last_command = items.get(node.id)
        node.is_new = node.id in new
    if principal.role == Role.dispatcher_external:
        for node in nodes:
            if isinstance(node.status, dict):
                node.status = {k: v for k, v in node.status.items() if k != "presence"}
    return nodes


@router.get("/buildings/{building_id}/sensor-trust", response_model=list[SensorTrustOut], tags=["nodes"])
async def building_sensor_trust(
    building_id: str,
    hours: int = Query(default=24, ge=1, le=168),
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external, Role.technician)),
    session: AsyncSession = Depends(get_session),
) -> list[dict]:
    if await session.get(Building, building_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    return await AnalyticsService(session).sensor_trust(building_id, hours=hours)


@router.get("/nodes/{node_id}/history", response_model=NodeHistoryOut, tags=["nodes"])
async def node_history(
    node_id: str,
    minutes: int = Query(default=60, ge=1, le=10080),
    fields: str | None = Query(default=None, description="comma-separated dotted paths, e.g. co.ppm,gas.adc"),
    principal: Principal = Depends(
        require_roles(Role.hoa_manager, Role.dispatcher_external, Role.resident, Role.technician)),
    session: AsyncSession = Depends(get_session),
) -> NodeHistoryOut:
    """History for charts. Residents: only nodes of their own unit or a common area (404
    otherwise) and only RESIDENT_HISTORY_FIELDS (anything else is a 400)."""
    resident = principal.role == Role.resident
    node = await session.get(Node, node_id)
    if node is None or (
        resident and node.zone_id not in await _resident_zone_ids(session, principal, node.building_id)
    ):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "node not found")
    try:
        wanted = parse_fields(fields, node.kind, resident, presence=principal.role != Role.dispatcher_external)
    except PermissionError as exc:
        raise HTTPException(status.HTTP_403_FORBIDDEN, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc
    points = await NodeService(session).history(node, minutes, wanted)
    return NodeHistoryOut(node_id=node.id, minutes=minutes, fields=wanted, points=points)


@router.patch("/nodes/{node_id}", response_model=NodeOut, tags=["nodes"])
async def update_node(
    node_id: str,
    req: NodeUpdate,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.technician)),
    session: AsyncSession = Depends(get_session),
) -> NodeOut:
    """Rename a node or move it (with its Device rows) to another zone."""
    node = await session.get(Node, node_id)
    if node is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "node not found")
    svc = NodeService(session)
    if req.zone_id is not None:
        zone = await session.get(Zone, req.zone_id)
        if zone is None:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "unknown zone")
        await svc.move(node, zone)
    if req.name is not None:
        node.name = req.name
    await session.commit()
    await broadcast_node(node)
    return (await svc.node_outs([node]))[0]


# --------------------------------------------------------------------------- #
# Care profiles: special needs, GDPR art. 9 health data (docs/HARDWARE.md section 4).
# Residents manage only their own; managers/dispatchers see them only in the roster of
# an open incident. Audit entries carry ids only, never names, needs or notes.
# --------------------------------------------------------------------------- #
def care_ready() -> None:
    """503 (via the CareUnavailable handler) while CANARY_CARE_KEY is missing or malformed."""
    care.cipher()


async def _own_profile(session: AsyncSession, principal: Principal, profile_id: str) -> CareProfile:
    profile = await session.get(CareProfile, profile_id)
    if profile is None or profile.owner_user_id != principal.user_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "care profile not found")
    return profile


async def _apply_care_profile(
    session: AsyncSession, principal: Principal, profile: CareProfile, req: CareProfileIn
) -> None:
    """Validate ownership / the single is_self rule and write `req` (encrypted) into `profile`."""
    unit = await care.residential_unit(session, principal.user_id, req.unit_id)
    if unit is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unit not found")
    if req.is_self:
        other = await session.scalar(select(CareProfile.id).where(CareProfile.person_user_id == principal.user_id))
        if other is not None and other != profile.id:
            raise HTTPException(status.HTTP_409_CONFLICT, "you already have a care profile for yourself")
    now = datetime.now(timezone.utc)
    profile.building_id, profile.unit_id = unit.building_id, unit.id
    profile.person_user_id = principal.user_id if req.is_self else None
    profile.consent_ts = profile.updated_ts = now  # consent is given again with every save
    care.seal(profile, req)


async def _commit_care(session: AsyncSession) -> None:
    try:
        await session.commit()
    except IntegrityError as exc:  # a concurrent second is_self profile
        await session.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "you already have a care profile for yourself") from exc


def _care_audit(principal: Principal, action: str, profile_id: str) -> AuditLogEntry:
    return AuditLogEntry(actor=principal.user_id, action=action, target=profile_id)


@router.get("/me/care-profiles", response_model=list[CareProfileOut], tags=["care"])
async def my_care_profiles(
    principal: Principal = Depends(require_roles(Role.resident)),
    _: None = Depends(care_ready),
    session: AsyncSession = Depends(get_session),
) -> list[CareProfileOut]:
    profiles = (
        await session.scalars(
            select(CareProfile)
            .where(CareProfile.owner_user_id == principal.user_id)
            .order_by(CareProfile.created_ts, CareProfile.id)
        )
    ).all()
    return await care.profile_outs(session, list(profiles))


@router.post("/me/care-profiles", response_model=CareProfileOut, status_code=status.HTTP_201_CREATED, tags=["care"])
async def create_care_profile(
    req: CareProfileIn,
    principal: Principal = Depends(require_roles(Role.resident)),
    _: None = Depends(care_ready),
    session: AsyncSession = Depends(get_session),
) -> CareProfileOut:
    profile = CareProfile(owner_user_id=principal.user_id)
    await _apply_care_profile(session, principal, profile, req)
    profile.created_ts = profile.updated_ts
    session.add(profile)
    await session.flush()
    session.add(_care_audit(principal, "care_profile_created", profile.id))
    await _commit_care(session)
    return (await care.profile_outs(session, [profile]))[0]


@router.put("/me/care-profiles/{profile_id}", response_model=CareProfileOut, tags=["care"])
async def update_care_profile(
    profile_id: str,
    req: CareProfileIn,
    principal: Principal = Depends(require_roles(Role.resident)),
    _: None = Depends(care_ready),
    session: AsyncSession = Depends(get_session),
) -> CareProfileOut:
    profile = await _own_profile(session, principal, profile_id)
    await _apply_care_profile(session, principal, profile, req)
    session.add(_care_audit(principal, "care_profile_updated", profile.id))
    await _commit_care(session)
    return (await care.profile_outs(session, [profile]))[0]


@router.delete("/me/care-profiles/{profile_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["care"])
async def delete_care_profile(
    profile_id: str,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """Withdraw consent: hard delete with its check-ins. Works even without CANARY_CARE_KEY."""
    profile = await _own_profile(session, principal, profile_id)
    await session.execute(delete(CareCheckIn).where(CareCheckIn.care_profile_id == profile.id))
    await session.delete(profile)
    session.add(_care_audit(principal, "care_profile_deleted", profile_id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/incidents/{incident_id}/care-checkin", tags=["care"])
async def care_check_in(
    incident_id: str,
    req: CareCheckInRequest,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> dict:
    """A resident reports one of their care profiles during an open incident of their building."""
    incident = await session.get(Incident, incident_id)
    if incident is None or not await _in_scope(session, principal, incident.building_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    if not care.is_active(incident):
        raise HTTPException(status.HTTP_409_CONFLICT, "incident is not active")
    profile = await _own_profile(session, principal, req.care_profile_id)
    if profile.building_id != incident.building_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "care profile not found")
    session.add(CareCheckIn(incident_id=incident_id, care_profile_id=profile.id, by_user_id=principal.user_id,
                            status=req.status))
    await session.commit()
    await manager.broadcast(
        incident.building_id,
        {  # ids and status only: no names, needs or notes on the building's WebSocket
            "type": "care_checkin",
            "incident_id": incident_id,
            "building_id": incident.building_id,
            "care_profile_id": profile.id,
            "status": req.status,
            "ts": datetime.now(timezone.utc).isoformat(),
        },
    )
    return {"ok": True}


# --------------------------------------------------------------------------- #
# Incidents
# --------------------------------------------------------------------------- #
async def _incidents_out(session: AsyncSession, incidents: list[Incident]) -> list[IncidentOut]:
    """Incidents with their latest hazard signature (one extra query for the batch)."""
    latest = await AnalyticsService(session).latest_signatures([i.id for i in incidents])
    out = []
    for incident in incidents:
        item = IncidentOut.model_validate(incident)
        row = latest.get(incident.id)
        item.signature = SignatureOut.model_validate(row) if row is not None else None
        out.append(item)
    return out


@router.get("/buildings/{building_id}/incidents", response_model=list[IncidentOut], tags=["incidents"])
async def list_incidents(
    building_id: str,
    active: bool = Query(default=False),
    _: Principal = Depends(building_reader),
    session: AsyncSession = Depends(get_session),
) -> list[IncidentOut]:
    q = select(Incident).where(Incident.building_id == building_id)
    if active:
        q = q.where(Incident.state.in_([s.value for s in OPEN_INCIDENT_STATES]))
    q = q.order_by(Incident.opened_ts.desc())
    return await _incidents_out(session, list((await session.scalars(q)).all()))


@router.get("/incidents/{incident_id}", response_model=IncidentOut, tags=["incidents"])
async def get_incident(
    incident_id: str,
    _: Principal = Depends(incident_reader),
    session: AsyncSession = Depends(get_session),
) -> IncidentOut:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    return (await _incidents_out(session, [incident]))[0]


@router.get("/incidents/{incident_id}/events", response_model=list[IncidentEventOut], tags=["incidents"])
async def incident_events(
    incident_id: str,
    _: Principal = Depends(incident_reader),
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
        priority_awaiting=care.awaiting(await care.priority_statuses(session, incident)),  # a count, no details
    )


@router.get("/incidents/{incident_id}/roster", response_model=RosterOut, tags=["incidents"])
async def incident_roster(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> RosterOut:
    """Named residents + their live check-in status for an incident: who is safe, who needs
    help, who is still unaccounted. The actionable detail behind the accounting counts.
    `priority` lists care profiles (health data) only while the incident is open; every
    read that returns them is audited."""
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")

    svc = OccupancyService(session)
    people = await svc.roster(incident_id, incident.building_id)
    safe, needs_help, awaiting = svc.roster_summary(people)
    statuses = await care.priority_statuses(session, incident)
    priority = await care.priority_people(session, statuses)
    if priority:
        session.add(
            AuditLogEntry(
                incident_id=incident_id,
                actor=principal.user_id,
                action="care_profile_view",
                target=incident.building_id,
                identity_unlock=True,
                detail={"count": len(priority)},
            )
        )
        await session.commit()
    where = dict((await session.execute(
        select(ResidentLocation.user_id, ResidentLocation.location).where(ResidentLocation.incident_id == incident_id)
    )).all())
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
                location=where.get(p.user_id),
            )
            for p in people
        ],
        priority=priority,
        priority_awaiting=care.awaiting(statuses),
    )


TRIANGULATION_HISTORY_MAX = 500


@router.get("/incidents/{incident_id}/fusion", response_model=FusionExplanationOut, tags=["incidents"])
async def incident_fusion_explanation(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> dict:
    incident = await session.get(Incident, incident_id)
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    return await AnalyticsService(session).fusion_explanation(incident)


@router.get(
    "/incidents/{incident_id}/triangulation/history", response_model=TriangulationHistoryOut, tags=["incidents"]
)
async def incident_triangulation_history(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> TriangulationHistoryOut:
    """Every distinct estimate, oldest first; over 500 they are evenly thinned (first and last kept)."""
    if await session.get(Incident, incident_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    ids = (
        await session.scalars(
            select(TriangulationSnapshot.id)
            .where(TriangulationSnapshot.incident_id == incident_id)
            .order_by(TriangulationSnapshot.ts, TriangulationSnapshot.id)
        )
    ).all()
    if len(ids) > TRIANGULATION_HISTORY_MAX:
        step = (len(ids) - 1) / (TRIANGULATION_HISTORY_MAX - 1)
        ids = [ids[round(i * step)] for i in range(TRIANGULATION_HISTORY_MAX)]
    rows = (
        await session.scalars(
            select(TriangulationSnapshot)
            .where(TriangulationSnapshot.id.in_(ids))
            .order_by(TriangulationSnapshot.ts, TriangulationSnapshot.id)
        )
    ).all() if ids else []
    return TriangulationHistoryOut(
        incident_id=incident_id,
        snapshots=[
            TriangulationSnapshotOut(
                ts=r.ts, source_zone_id=r.source_zone_id, source_x=r.source_x, source_y=r.source_y,
                confidence=r.confidence, method=r.method, n_contributors=r.n_contributors,
                airflow_applied=r.airflow_applied,
                contributors=[TriangulationContributor(**c) for c in r.contributors or []],
            )
            for r in rows
        ],
    )


@router.get("/incidents/{incident_id}/escalations", response_model=list[EscalationOut], tags=["incidents"])
async def incident_escalations(
    incident_id: str,
    _: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> list[EscalationOut]:
    """Escalation webhook events for the incident (oldest first) and how their delivery went."""
    if await session.get(Incident, incident_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    rows = (
        await session.scalars(
            select(EscalationDelivery)
            .where(EscalationDelivery.incident_id == incident_id)
            .order_by(EscalationDelivery.ts, EscalationDelivery.id)
        )
    ).all()
    events: dict[str, list[EscalationDelivery]] = {}
    for row in rows:
        events.setdefault(row.event_id, []).append(row)
    out = []
    for event_id, attempts in events.items():
        last = attempts[-1]
        out.append(EscalationOut(
            event_id=event_id, state=last.state, attempts=max(a.attempt for a in attempts),
            last_status=last.status_code, last_error=last.error, delivered=any(a.delivered for a in attempts),
            ts=last.ts,
        ))
    return out


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
    if incident is None or not await _in_scope(session, principal, incident.building_id):
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


@router.post("/incidents/{incident_id}/location", response_model=LocationOut, tags=["incidents"])
async def report_location(
    incident_id: str,
    req: LocationIn,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> LocationOut:
    """The resident's answer to "Where are you now?" (home / elsewhere in the building / outside).
    Latest answer wins; shown next to their name in the incident roster."""
    incident = await session.get(Incident, incident_id)
    if incident is None or not await _in_scope(session, principal, incident.building_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    now = datetime.now(timezone.utc)
    row = await session.get(ResidentLocation, (incident_id, principal.user_id))
    if row is None:
        session.add(ResidentLocation(incident_id=incident_id, user_id=principal.user_id, location=req.location.value, ts=now))
    else:
        row.location, row.ts = req.location.value, now
    await session.commit()
    await manager.broadcast(incident.building_id, {
        "type": "location", "incident_id": incident_id, "building_id": incident.building_id,
        "user_id": principal.user_id, "location": req.location.value, "ts": now.isoformat(),
    })
    return LocationOut(incident_id=incident_id, location=req.location.value, ts=now)


@router.post("/incidents/{incident_id}/dismiss", response_model=IncidentOut, tags=["incidents"])
async def dismiss_incident(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> IncidentOut:
    try:
        incident = await IncidentService(session).dismiss(incident_id, actor=principal.username)
    except ValueError as exc:
        # Illegal state transition (e.g. dismissing an already-evacuating incident) is a
        # conflict, not a server error — return 409 so the dashboard shows a clear message.
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    await session.commit()
    return (await _incidents_out(session, [incident]))[0]


@router.post("/incidents/{incident_id}/order-evacuation", response_model=IncidentOut, tags=["incidents"])
async def order_evacuation(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> IncidentOut:
    try:
        incident = await IncidentService(session).order_evacuation(incident_id, actor=principal.username)
    except ValueError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    await session.commit()
    return (await _incidents_out(session, [incident]))[0]


@router.post("/incidents/{incident_id}/resolve", response_model=IncidentOut, tags=["incidents"])
async def resolve_incident(
    incident_id: str,
    principal: Principal = Depends(require_roles(Role.hoa_manager, Role.dispatcher_external)),
    session: AsyncSession = Depends(get_session),
) -> IncidentOut:
    try:
        incident = await IncidentService(session).resolve(incident_id, actor=principal.username)
    except ValueError as exc:
        raise HTTPException(status.HTTP_409_CONFLICT, str(exc)) from exc
    if incident is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "incident not found")
    await session.commit()
    return (await _incidents_out(session, [incident]))[0]


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
        principal = decode_token(token)  # authenticate before accepting
    except HTTPException:
        await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        return
    async with SessionLocal() as session:
        allowed = await _in_scope(session, principal, building_id)
    if not allowed:  # a resident subscribing to another building
        await ws.close(code=status.WS_1008_POLICY_VIOLATION)
        return
    await manager.connect(building_id, ws)
    try:
        while True:
            # We don't expect client messages; this keeps the socket open.
            await ws.receive_text()
    except WebSocketDisconnect:
        await manager.disconnect(building_id, ws)
