"""Idempotent demo seed: one building, sensors, users, evacuation geometry, ARC.

IDs match the examples in ARCHITECTURE.md section 5 so the simulator's defaults
line up with real rows out of the box.
"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.enums import ExternalIntegrationKind, Role, SensorType
from app.models import (
    AssemblyPoint,
    Building,
    Device,
    EvacuationRoute,
    ExternalIntegration,
    Floor,
    ResidentUnit,
    Unit,
    User,
    Zone,
)

BUILDING_ID = "bld_007"


async def seed(session: AsyncSession) -> None:
    if await session.get(Building, BUILDING_ID) is not None:
        return  # already seeded

    session.add(
        Building(id=BUILDING_ID, name="Bloc A1", address="Str. Exemplu 12, Bucuresti", timezone="Europe/Bucharest")
    )
    session.add(Floor(id="flr_03", building_id=BUILDING_ID, level=3, label="Etaj 3"))

    # residential units + one common-area unit on floor 3
    session.add(Unit(id="unit_0312", building_id=BUILDING_ID, floor_id="flr_03", label="Ap. 12", kind="residential"))
    session.add(Unit(id="unit_0313", building_id=BUILDING_ID, floor_id="flr_03", label="Ap. 13", kind="residential"))
    session.add(Unit(id="unit_0314", building_id=BUILDING_ID, floor_id="flr_03", label="Ap. 14", kind="residential"))
    session.add(Unit(id="common", building_id=BUILDING_ID, floor_id="flr_03", label="Comun Etaj 3", kind="common"))

    # pos_x/pos_y: simple floor-3 layout in metres (arbitrary origin) for triangulation.
    zones = [
        Zone(id="zone_kitchen", building_id=BUILDING_ID, floor_id="flr_03", unit_id="unit_0312", label="Bucatarie", kind="kitchen", pos_x=2.0, pos_y=2.0),
        Zone(id="zone_bedroom", building_id=BUILDING_ID, floor_id="flr_03", unit_id="unit_0312", label="Dormitor", kind="bedroom", pos_x=8.0, pos_y=2.0),
        Zone(id="zone_hallway", building_id=BUILDING_ID, floor_id="flr_03", unit_id="common", label="Hol", kind="hallway", pos_x=5.0, pos_y=5.0),
        Zone(id="zone_boiler", building_id=BUILDING_ID, floor_id="flr_03", unit_id="common", label="Centrala", kind="boiler", pos_x=2.0, pos_y=8.0),
    ]
    for z in zones:
        session.add(z)

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
    ]
    for u in users:
        session.add(u)
    # Resident -> home unit. ana & ioana share Ap. 12; radu in Ap. 13; elena in Ap. 14.
    resident_units = [
        ("usr_ana", "unit_0312"),
        ("usr_ioana", "unit_0312"),
        ("usr_radu", "unit_0313"),
        ("usr_elena", "unit_0314"),
    ]
    for user_id, unit_id in resident_units:
        session.add(ResidentUnit(user_id=user_id, unit_id=unit_id, building_id=BUILDING_ID))

    session.add(AssemblyPoint(id="ap_main", building_id=BUILDING_ID, label="Punct adunare - parcare fata", lat=44.4268, lon=26.1025))
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


async def seed_if_empty() -> None:
    async with SessionLocal() as session:
        existing = await session.scalar(select(Building.id).limit(1))
        if existing is None:
            await seed(session)
