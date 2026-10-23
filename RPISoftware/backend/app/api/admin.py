"""Admin API: users, floors, units, zones (docs/HARDWARE.md section 4).

system_admin: everything. hoa_manager: only the buildings they run (app.api.scope), and only
role=resident users. technician: floors, units, zones and nodes of those buildings, no users.
Other roles: 403. Out-of-scope ids answer 404. Every change is audited
with the changed field names only (never values).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.nodes import NodeService, device_ids
from app.api.scope import managed_buildings, manages
from app.db import get_session
from app.enums import Role
from app.ingestion import hardware
from app.models import (
    AuditLogEntry,
    Building,
    Device,
    DeviceCommand,
    FirmwareUpdate,
    Floor,
    Node,
    NodeFirmwareSeen,
    NodeInbox,
    NodeOtaTarget,
    ResidentUnit,
    StaffBuilding,
    Unit,
    User,
    UserStatus,
    Zone,
)
from app.schemas import (
    AdminUnitOut,
    AdminUnitRef,
    AdminUserIn,
    AdminUserOut,
    AdminUserUpdate,
    AdminZoneOut,
    FloorIn,
    FloorOut,
    UnitIn,
    UnitUpdate,
    ZoneIn,
    ZoneNodeOut,
    ZoneUpdate,
)
from app.security import Principal, get_current_principal

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])


class Scope:
    def __init__(self, principal: Principal, buildings: set[str] | None) -> None:
        self.principal, self.buildings = principal, buildings

    @property
    def is_admin(self) -> bool:
        return self.principal.role == Role.system_admin

    def check(self, building_id: str | None, what: str) -> None:
        if building_id is None or not manages(self.buildings, building_id):
            raise HTTPException(status.HTTP_404_NOT_FOUND, f"{what} not found")

    def audit(self, action: str, target: str, fields: list[str]) -> AuditLogEntry:
        return AuditLogEntry(actor=self.principal.user_id, action=action, target=target, detail={"fields": fields})


async def staff_scope(
    principal: Principal = Depends(get_current_principal), session: AsyncSession = Depends(get_session)
) -> Scope:
    if principal.role not in (Role.system_admin, Role.hoa_manager, Role.technician):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")
    return Scope(principal, await managed_buildings(session, principal))


async def accounts_scope(scope: Scope = Depends(staff_scope)) -> Scope:
    """Accounts are for admins and managers: a technician installs rooms and sensors only."""
    if scope.principal.role == Role.technician:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")
    return scope


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:10]}"


async def _building(session: AsyncSession, scope: Scope, building_id: str) -> Building:
    scope.check(building_id, "building")
    building = await session.get(Building, building_id)
    if building is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "building not found")
    return building


# --------------------------------------------------------------------------- #
# Users
# --------------------------------------------------------------------------- #
async def _user_outs(session: AsyncSession, users: list[User]) -> list[AdminUserOut]:
    ids = [u.id for u in users]
    inactive = set((await session.scalars(
        select(UserStatus.user_id).where(UserStatus.user_id.in_(ids), UserStatus.active.is_(False)))).all())
    units: dict[str, list[AdminUnitRef]] = {}
    for user_id, unit_id, label in (await session.execute(
        select(ResidentUnit.user_id, Unit.id, Unit.label).join(Unit, Unit.id == ResidentUnit.unit_id)
        .where(ResidentUnit.user_id.in_(ids)).order_by(Unit.label, Unit.id)
    )).all():
        units.setdefault(user_id, []).append(AdminUnitRef(unit_id=unit_id, unit_label=label))
    return [
        AdminUserOut(user_id=u.id, username=u.username, display_name=u.display_name, role=u.role, phone=u.phone,
                     email=u.email, active=u.id not in inactive, units=units.get(u.id, []))
        for u in users
    ]


async def _units_for(session: AsyncSession, scope: Scope, unit_ids: list[str]) -> list[Unit]:
    units = []
    for unit_id in dict.fromkeys(unit_ids):
        unit = await session.get(Unit, unit_id)
        scope.check(unit.building_id if unit else None, "unit")
        if unit.kind != "residential":
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, f"{unit_id} is not a residential unit")
        units.append(unit)
    return units


async def _editable_user(session: AsyncSession, scope: Scope, user_id: str) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "user not found")
    if not scope.is_admin:
        if user.role != Role.resident.value:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "managers can only edit residents")
        buildings = set((await session.scalars(
            select(ResidentUnit.building_id).where(ResidentUnit.user_id == user.id))).all())
        if not all(manages(scope.buildings, b) for b in buildings):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "user not found")
    return user


@router.get("/users", response_model=list[AdminUserOut])
async def list_users(
    building_id: str | None = Query(default=None),
    scope: Scope = Depends(accounts_scope),
    session: AsyncSession = Depends(get_session),
) -> list[AdminUserOut]:
    """Users of a building (residents by unit, staff by assignment), or every user in scope."""
    q = select(User).order_by(User.display_name, User.id)
    buildings = scope.buildings
    if building_id is not None:
        await _building(session, scope, building_id)
        buildings = {building_id}
    if buildings is not None:
        q = q.where(or_(
            User.id.in_(select(ResidentUnit.user_id).where(ResidentUnit.building_id.in_(buildings))),
            User.id.in_(select(StaffBuilding.user_id).where(StaffBuilding.building_id.in_(buildings))),
        ))
    return await _user_outs(session, list((await session.scalars(q)).all()))


@router.post("/users", response_model=AdminUserOut, status_code=status.HTTP_201_CREATED)
async def create_user(
    req: AdminUserIn, scope: Scope = Depends(accounts_scope), session: AsyncSession = Depends(get_session)
) -> AdminUserOut:
    if not scope.is_admin and req.role != Role.resident.value:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "managers can only create residents")
    if req.unit_ids and req.role != Role.resident.value:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "only residents have units")
    units = await _units_for(session, scope, req.unit_ids)
    if await session.scalar(select(User.id).where(User.username == req.username)) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "username already taken")
    user = User(id=_new_id("usr"), username=req.username, display_name=req.display_name, role=req.role,
                phone=req.phone, email=req.email)
    session.add(user)
    await session.flush()
    for unit in units:
        session.add(ResidentUnit(user_id=user.id, unit_id=unit.id, building_id=unit.building_id))
    session.add(scope.audit("admin_user_created", user.id, sorted(req.model_fields_set)))
    await session.commit()
    return (await _user_outs(session, [user]))[0]


@router.patch("/users/{user_id}", response_model=AdminUserOut)
async def update_user(
    user_id: str, req: AdminUserUpdate, scope: Scope = Depends(accounts_scope),
    session: AsyncSession = Depends(get_session),
) -> AdminUserOut:
    user = await _editable_user(session, scope, user_id)
    [current] = await _user_outs(session, [user])
    if req.role is not None and req.role != user.role and not scope.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "managers can only manage residents")
    if req.active is False and user.id == scope.principal.user_id:
        raise HTTPException(status.HTTP_409_CONFLICT, "you cannot deactivate yourself")
    role = req.role or user.role
    unit_ids = req.unit_ids if req.unit_ids is not None else [u.unit_id for u in current.units]
    if unit_ids and role != Role.resident.value:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "only residents have units; send unit_ids: []")
    changed = []
    for name in ("display_name", "role", "phone", "email"):
        value = getattr(req, name)
        if value is not None and value != getattr(user, name):
            setattr(user, name, value)
            changed.append(name)
    if req.unit_ids is not None and sorted(set(req.unit_ids)) != sorted(u.unit_id for u in current.units):
        units = await _units_for(session, scope, req.unit_ids)
        await session.execute(delete(ResidentUnit).where(ResidentUnit.user_id == user.id))
        for unit in units:
            session.add(ResidentUnit(user_id=user.id, unit_id=unit.id, building_id=unit.building_id))
        changed.append("unit_ids")
    if req.active is not None and req.active != current.active:
        account = await session.get(UserStatus, user.id) or UserStatus(user_id=user.id)
        account.active, account.updated_ts = req.active, datetime.now(timezone.utc)
        session.add(account)
        changed.append("active")
    if changed:
        session.add(scope.audit("admin_user_updated", user.id, changed))
        await session.commit()
    return (await _user_outs(session, [user]))[0]


# --------------------------------------------------------------------------- #
# Floors / units
# --------------------------------------------------------------------------- #
@router.get("/buildings/{building_id}/floors", response_model=list[FloorOut])
async def list_floors(
    building_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> list[FloorOut]:
    await _building(session, scope, building_id)
    floors = await session.scalars(
        select(Floor).where(Floor.building_id == building_id).order_by(Floor.level, Floor.id))
    return [FloorOut(floor_id=f.id, label=f.label, level=f.level) for f in floors.all()]


@router.post("/buildings/{building_id}/floors", response_model=FloorOut, status_code=status.HTTP_201_CREATED)
async def create_floor(
    building_id: str, req: FloorIn, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> FloorOut:
    await _building(session, scope, building_id)
    floor = Floor(id=_new_id("flr"), building_id=building_id, label=req.label, level=req.level)
    session.add(floor)
    session.add(scope.audit("admin_floor_created", floor.id, ["label", "level"]))
    await session.commit()
    return FloorOut(floor_id=floor.id, label=floor.label, level=floor.level)


async def _unit_outs(session: AsyncSession, units: list[Unit]) -> list[AdminUnitOut]:
    ids = [u.id for u in units]
    floors = dict((await session.execute(
        select(Floor.id, Floor.label).where(Floor.id.in_({u.floor_id for u in units})))).all())
    residents = dict((await session.execute(
        select(ResidentUnit.unit_id, func.count()).where(ResidentUnit.unit_id.in_(ids))
        .group_by(ResidentUnit.unit_id))).all())
    return [
        AdminUnitOut(unit_id=u.id, label=u.label, floor_id=u.floor_id, floor_label=floors.get(u.floor_id),
                     kind=u.kind, residents=residents.get(u.id, 0))
        for u in units
    ]


@router.get("/buildings/{building_id}/units", response_model=list[AdminUnitOut])
async def list_units(
    building_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> list[AdminUnitOut]:
    await _building(session, scope, building_id)
    units = await session.scalars(select(Unit).where(Unit.building_id == building_id).order_by(Unit.label, Unit.id))
    return await _unit_outs(session, list(units.all()))


@router.post("/buildings/{building_id}/units", response_model=AdminUnitOut, status_code=status.HTTP_201_CREATED)
async def create_unit(
    building_id: str, req: UnitIn, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> AdminUnitOut:
    await _building(session, scope, building_id)
    floor = await session.get(Floor, req.floor_id)
    if floor is None or floor.building_id != building_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "floor not found")
    unit = Unit(id=_new_id("unit"), building_id=building_id, floor_id=floor.id, label=req.label, kind=req.kind)
    session.add(unit)
    session.add(scope.audit("admin_unit_created", unit.id, ["label", "floor_id", "kind"]))
    await session.commit()
    return (await _unit_outs(session, [unit]))[0]


@router.patch("/units/{unit_id}", response_model=AdminUnitOut)
async def update_unit(
    unit_id: str, req: UnitUpdate, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> AdminUnitOut:
    unit = await session.get(Unit, unit_id)
    scope.check(unit.building_id if unit else None, "unit")
    [current] = await _unit_outs(session, [unit])
    if req.kind == "common" and unit.kind != "common" and current.residents:
        raise HTTPException(status.HTTP_409_CONFLICT, "the unit still has residents")
    changed = [name for name in ("label", "kind") if getattr(req, name) is not None
               and getattr(req, name) != getattr(unit, name)]
    for name in changed:
        setattr(unit, name, getattr(req, name))
    if changed:
        session.add(scope.audit("admin_unit_updated", unit.id, changed))
        await session.commit()
    return (await _unit_outs(session, [unit]))[0]


# --------------------------------------------------------------------------- #
# Zones
# --------------------------------------------------------------------------- #
async def _zone_outs(session: AsyncSession, zones: list[Zone]) -> list[AdminZoneOut]:
    zone_ids = [z.id for z in zones]
    units = dict((await session.execute(
        select(Unit.id, Unit.label).where(Unit.id.in_({z.unit_id for z in zones})))).all())
    floors = dict((await session.execute(
        select(Floor.id, Floor.label).where(Floor.id.in_({z.floor_id for z in zones})))).all())
    nodes = list((await session.scalars(
        select(Node).where(Node.zone_id.in_(zone_ids)).order_by(Node.name, Node.id))).all())
    analyses = await NodeService(session).analyses(nodes, datetime.now(timezone.utc))
    by_zone: dict[str, list[ZoneNodeOut]] = {}
    for n in nodes:
        by_zone.setdefault(n.zone_id, []).append(
            ZoneNodeOut(node_id=n.id, name=n.name, kind=n.kind, online=n.online, status=analyses[n.id].status))
    return [
        AdminZoneOut(zone_id=z.id, label=z.label, kind=z.kind, unit_id=z.unit_id, unit_label=units.get(z.unit_id),
                     floor_id=z.floor_id, floor_label=floors.get(z.floor_id), pos_x=z.pos_x, pos_y=z.pos_y,
                     nodes=by_zone.get(z.id, []))
        for z in zones
    ]


async def _zone_unit(session: AsyncSession, building_id: str, unit_id: str) -> Unit:
    unit = await session.get(Unit, unit_id)
    if unit is None or unit.building_id != building_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unit not found")
    return unit


@router.get("/buildings/{building_id}/zones", response_model=list[AdminZoneOut])
async def list_zones(
    building_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> list[AdminZoneOut]:
    await _building(session, scope, building_id)
    zones = await session.scalars(select(Zone).where(Zone.building_id == building_id).order_by(Zone.label, Zone.id))
    return await _zone_outs(session, list(zones.all()))


@router.post("/buildings/{building_id}/zones", response_model=AdminZoneOut, status_code=status.HTTP_201_CREATED)
async def create_zone(
    building_id: str, req: ZoneIn, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> AdminZoneOut:
    await _building(session, scope, building_id)
    unit = await _zone_unit(session, building_id, req.unit_id)
    zone = Zone(id=_new_id("zone"), building_id=building_id, floor_id=unit.floor_id, unit_id=unit.id,
                label=req.label, kind=req.kind, pos_x=req.pos_x, pos_y=req.pos_y)
    session.add(zone)
    session.add(scope.audit("admin_zone_created", zone.id, sorted(req.model_fields_set)))
    await session.commit()
    return (await _zone_outs(session, [zone]))[0]


@router.patch("/zones/{zone_id}", response_model=AdminZoneOut)
async def update_zone(
    zone_id: str, req: ZoneUpdate, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> AdminZoneOut:
    zone = await session.get(Zone, zone_id)
    scope.check(zone.building_id if zone else None, "zone")
    changed = []
    for name in ("label", "kind", "pos_x", "pos_y"):
        value = getattr(req, name)
        if value is not None and value != getattr(zone, name):
            setattr(zone, name, value)
            changed.append(name)
    if req.unit_id is not None and req.unit_id != zone.unit_id:
        unit = await _zone_unit(session, zone.building_id, req.unit_id)
        zone.unit_id, zone.floor_id = unit.id, unit.floor_id
        # devices placed in the zone follow it to the new unit / floor
        await session.execute(update(Device).where(Device.zone_id == zone.id)
                              .values(unit_id=unit.id, floor_id=unit.floor_id))
        changed.append("unit_id")
    if changed:
        session.add(scope.audit("admin_zone_updated", zone.id, changed))
        await session.commit()
    return (await _zone_outs(session, [zone]))[0]


@router.delete("/zones/{zone_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_zone(
    zone_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> Response:
    zone = await session.get(Zone, zone_id)
    scope.check(zone.building_id if zone else None, "zone")
    in_use = await session.scalar(select(Node.id).where(Node.zone_id == zone.id).limit(1)) or await session.scalar(
        select(Device.id).where(Device.zone_id == zone.id).limit(1))
    if in_use is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "nodes or devices are still assigned to this zone")
    await session.delete(zone)
    session.add(scope.audit("admin_zone_deleted", zone_id, []))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------- #
# Nodes
# --------------------------------------------------------------------------- #
@router.delete("/nodes/{node_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_node(
    node_id: str, scope: Scope = Depends(staff_scope), session: AsyncSession = Depends(get_session)
) -> Response:
    """Remove an offline node with its logical devices, command and firmware history. Raw snapshots and
    readings stay (incident evidence; nothing references them by key; retention prunes them),
    so the same base topic coming back re-registers as usual and sees that earlier history."""
    node = await session.get(Node, node_id)
    scope.check(node.building_id if node else None, "node")
    if node.online:
        raise HTTPException(status.HTTP_409_CONFLICT, "node online")
    await session.execute(delete(Device).where(Device.id.in_(device_ids(node.id, node.kind))))
    await session.execute(delete(DeviceCommand).where(DeviceCommand.node_id == node.id))
    await session.execute(delete(NodeInbox).where(NodeInbox.node_id == node.id))
    for model in (NodeOtaTarget, NodeFirmwareSeen, FirmwareUpdate):
        await session.execute(delete(model).where(model.node_id == node.id))
    base = node.mqtt_base
    await session.delete(node)
    session.add(scope.audit("admin_node_deleted", node_id, []))
    await session.commit()
    hardware.forget_node(node_id, base)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
