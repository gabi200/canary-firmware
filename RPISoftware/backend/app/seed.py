"""Idempotent demo seed: one building, sensors, users, evacuation geometry, ARC.

IDs match the examples in ARCHITECTURE.md section 5 so the simulator's defaults
line up with real rows out of the box.
"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.nodes import NodeService
from app.config import settings
from app.db import SessionLocal
from app.enums import ExternalIntegrationKind, Role, SensorType
from app.models import (
    AssemblyPoint,
    Building,
    Device,
    EvacuationRoute,
    ExternalIntegration,
    Floor,
    Node,
    ResidentUnit,
    StaffBuilding,
    Unit,
    User,
    Zone,
)

BUILDING_ID = "bld_007"


TECH_ID = "usr_tech"


async def seed(session: AsyncSession) -> None:
    if await session.get(Building, BUILDING_ID) is not None:
        return  # already seeded

    session.add(
        Building(id=BUILDING_ID, name="Bloc A1", address="Str. Exemplu 12, Bucuresti", timezone="Europe/Bucharest")
    )
    # Postgres enforces foreign keys, and with no relationship()s a flush orders its INSERTs by
    # class name, not by dependency: flush each level before adding the rows that point at it.
    await session.flush()
    session.add(Floor(id="flr_03", building_id=BUILDING_ID, level=3, label="Etaj 3"))
    await session.flush()

    # residential units + one common-area unit on floor 3
    session.add(Unit(id="unit_0312", building_id=BUILDING_ID, floor_id="flr_03", label="Ap. 12", kind="residential"))
    session.add(Unit(id="unit_0313", building_id=BUILDING_ID, floor_id="flr_03", label="Ap. 13", kind="residential"))
    session.add(Unit(id="unit_0314", building_id=BUILDING_ID, floor_id="flr_03", label="Ap. 14", kind="residential"))
    session.add(Unit(id="common", building_id=BUILDING_ID, floor_id="flr_03", label="Spații comune", kind="common"))
    await session.flush()

    # pos_x/pos_y: simple floor-3 layout in metres (arbitrary origin) for triangulation.
    zones = [
        Zone(id="zone_kitchen", building_id=BUILDING_ID, floor_id="flr_03", unit_id="unit_0312", label="Bucătărie", kind="kitchen", pos_x=2.0, pos_y=2.0),
        Zone(id="zone_bedroom", building_id=BUILDING_ID, floor_id="flr_03", unit_id="unit_0312", label="Dormitor", kind="bedroom", pos_x=8.0, pos_y=2.0),
        Zone(id="zone_hallway", building_id=BUILDING_ID, floor_id="flr_03", unit_id="common", label="Hol scară", kind="hallway", pos_x=5.0, pos_y=5.0),
        Zone(id="zone_boiler", building_id=BUILDING_ID, floor_id="flr_03", unit_id="common", label="Centrală termică", kind="boiler", pos_x=2.0, pos_y=8.0),
    ]
    for z in zones:
        session.add(z)
    await session.flush()

    devices = [
        ("dev_gas_kitchen", "zone_kitchen", "unit_0312", SensorType.combustible_gas),
        ("dev_leak_kitchen", "zone_kitchen", "unit_0312", SensorType.water_leak),
        ("dev_co_bedroom", "zone_bedroom", "unit_0312", SensorType.co),
        ("dev_co_boiler", "zone_boiler", "common", SensorType.co),
        ("dev_gas_boiler", "zone_boiler", "common", SensorType.combustible_gas),
        ("dev_presence_unit", "zone_hallway", "common", SensorType.wifi_presence),
        ("dev_presence_bedroom", "zone_bedroom", "unit_0312", SensorType.wifi_presence),
    ]
    for dev_id, zone_id, unit_id, st in devices:
        session.add(
            Device(
                id=dev_id,
                building_id=BUILDING_ID,
                floor_id="flr_03",
                unit_id=unit_id,
                zone_id=zone_id,
                sensor_type=st.value,
                fw_version="1.4.2",
            )
        )

    users = [
        User(id="usr_ana", username="ana", display_name="Ana Popescu", role=Role.resident.value, phone="+40700000001"),
        User(id="usr_ioana", username="ioana", display_name="Ioana Popescu", role=Role.resident.value, phone="+40700000002"),
        User(id="usr_radu", username="radu", display_name="Radu Ionescu", role=Role.resident.value, phone="+40700000003"),
        User(id="usr_elena", username="elena", display_name="Elena Dumitru", role=Role.resident.value, phone="+40700000004"),
        User(id="usr_mihai", username="mihai", display_name="Mihai (administrator)", role=Role.hoa_manager.value),
        User(id="usr_disp", username="dispecer", display_name="Dispecer ARC", role=Role.dispatcher_external.value),
        User(id="usr_admin", username="admin", display_name="System Admin", role=Role.system_admin.value),
        User(id=TECH_ID, username="tehnician", display_name="Tehnician Canary", role=Role.technician.value),
    ]
    for u in users:
        session.add(u)
    await session.flush()
    # Resident -> home unit. ana & ioana share Ap. 12; radu in Ap. 13; elena in Ap. 14.
    resident_units = [
        ("usr_ana", "unit_0312"),
        ("usr_ioana", "unit_0312"),
        ("usr_radu", "unit_0313"),
        ("usr_elena", "unit_0314"),
    ]
    for user_id, unit_id in resident_units:
        session.add(ResidentUnit(user_id=user_id, unit_id=unit_id, building_id=BUILDING_ID))
    # the HOA manager runs this building (admin API scope)
    session.add(StaffBuilding(user_id="usr_mihai", building_id=BUILDING_ID))

    session.add(AssemblyPoint(id="ap_main", building_id=BUILDING_ID, label="Punct adunare - parcare fata", lat=44.4268, lon=26.1025))
    await session.flush()
    session.add(
        EvacuationRoute(
            id="er_flr03",
            building_id=BUILDING_ID,
            floor_id="flr_03",
            from_zone_id="zone_hallway",
            to_assembly_point_id="ap_main",
            label="Etaj 3 → scară → ieșire față",
            path=[
                {"id": "zone_hallway", "hint": "Mergeți spre scară, departe de centrală"},
                {
                    "id": "stairwell_main",
                    "label": "Scara principală",
                    "kind": "stairwell",
                    "hint": "Coborâți până la parter. Nu folosiți liftul.",
                },
                {
                    "id": "exit_front",
                    "label": "Ieșirea din față",
                    "kind": "exit",
                    "hint": "Ieșiți din clădire",
                },
                "ap_main",
            ],
        )
    )

    session.add(
        ExternalIntegration(
            building_id=BUILDING_ID,
            kind=ExternalIntegrationKind.arc.value,
            endpoint="https://arc.example.ro/incidents",
            sla_answer_secs=30,
            sla_call_to_112_secs=90,
            isu_agreement_signed=False,
            active=True,
        )
    )
    session.add(
        ExternalIntegration(
            building_id=BUILDING_ID,
            kind=ExternalIntegrationKind.gas_distributor.value,
            endpoint="https://distrigaz.example.ro/leaks",
            active=True,
        )
    )

    await session.commit()
    await ensure_live_building(session)


async def ensure_live_building(session: AsyncSession) -> None:
    """Idempotent: name the demo building "Demo" and create the real "Canary Live" building.
    Pre-existing real nodes move into it only on the run that creates it, in the same
    transaction, so a crash cannot leave the building without its nodes. Nodes are never deleted."""
    demo = await session.get(Building, settings.demo_building_id)
    if demo is not None and demo.name == "Bloc A1":
        demo.name = "Demo"
    live_id = settings.live_building_id
    if await session.get(Building, live_id) is None:
        session.add(Building(id=live_id, name="Canary Live", address="", timezone="Europe/Bucharest"))
        await session.flush()
        session.add(Floor(id="flr_live", building_id=live_id, level=0, label="Parter"))
        await session.flush()
        session.add(Unit(id="unit_live", building_id=live_id, floor_id="flr_live", label="Live", kind="common"))
        await session.flush()
        zone = Zone(id=settings.live_zone_id, building_id=live_id, floor_id="flr_live", unit_id="unit_live",
                    label="Presentation", kind="hallway", pos_x=0.0, pos_y=0.0)
        session.add(zone)
        if await session.get(User, "usr_mihai") is not None:
            session.add(StaffBuilding(user_id="usr_mihai", building_id=live_id))
        for user_id in ("usr_ana", "usr_ioana", "usr_radu", "usr_elena"):
            if await session.get(User, user_id) is not None:
                session.add(ResidentUnit(user_id=user_id, unit_id="unit_live", building_id=live_id))
        await session.flush()
        svc = NodeService(session)
        for node_id in settings.live_node_ids:
            node = await session.get(Node, node_id)
            if node is not None and node.building_id == settings.demo_building_id:
                await svc.move(node, zone)
    await session.commit()


async def seed_if_empty() -> None:
    async with SessionLocal() as session:
        existing = await session.scalar(select(Building.id).limit(1))
        if existing is None:
            await seed(session)
        elif await session.get(Building, BUILDING_ID) is not None and await session.get(User, TECH_ID) is None:
            # demo hubs seeded before the technician role existed get the login too
            session.add(User(id=TECH_ID, username="tehnician", display_name="Tehnician Canary",
                             role=Role.technician.value))
            await session.commit()
