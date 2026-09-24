"""Occupancy & victim-accounting service.

MVP fuses per-zone WiFi-presence estimates (anonymous counts) with resident
check-ins to compute unaccounted occupants. Accuracy is intentionally modest:
WiFi presence is device-bound not person-bound and zone-resolution is coarse
(see ARCHITECTURE.md section B). The number is a decision aid for responders,
never a guarantee that a zone is empty.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import ACCOUNTED_STATUSES, CheckInStatus, Role
from app.models import CheckIn, OccupancyEstimate, ResidentUnit, Unit, User

# Check-in statuses that mean a resident is confirmed out of danger.
_SAFE_STATUSES = frozenset({CheckInStatus.safe_outside, CheckInStatus.safe_inside})


@dataclass
class Accounting:
    incident_id: str
    occupancy_total: float
    accounted: int
    unaccounted: int
    needs_help: int
    zones_with_people: list[tuple[str, float]]


@dataclass
class RosterPerson:
    user_id: str
    display_name: str
    unit_id: str | None
    unit_label: str | None
    phone: str
    status: str  # safe_outside | safe_inside | needs_help | no_response | unknown
    source: str | None
    ts: datetime | None


class OccupancyService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def record_presence(
        self,
        building_id: str,
        zone_id: str,
        persons_est: float,
        confidence: float = 0.6,
        ts: datetime | None = None,
    ) -> OccupancyEstimate:
        est = OccupancyEstimate(
            building_id=building_id,
            zone_id=zone_id,
            persons_est=persons_est,
            confidence=confidence,
            ts=ts or datetime.now(timezone.utc),
        )
        self.session.add(est)
        return est

    async def latest_per_zone(self, building_id: str) -> dict[str, float]:
        """Latest persons_est per zone for a building.

        Polled every few seconds by dashboards, so the max-ts-per-zone is computed in
        SQL (index ix_occupancy_building_zone_ts) instead of loading every row ever.
        """
        newest = (
            select(OccupancyEstimate.zone_id, func.max(OccupancyEstimate.ts).label("ts"))
            .where(OccupancyEstimate.building_id == building_id)
            .group_by(OccupancyEstimate.zone_id)
            .subquery()
        )
        rows = await self.session.execute(
            select(OccupancyEstimate.zone_id, OccupancyEstimate.persons_est)
            .join(
                newest,
                (OccupancyEstimate.zone_id == newest.c.zone_id) & (OccupancyEstimate.ts == newest.c.ts),
            )
            .where(OccupancyEstimate.building_id == building_id)
            .order_by(OccupancyEstimate.id)
        )
        return {zone_id: persons_est for zone_id, persons_est in rows}

    async def accounting(self, incident_id: str, building_id: str) -> Accounting:
        per_zone = await self.latest_per_zone(building_id)
        total = sum(per_zone.values())

        check_ins = (
            await self.session.scalars(
                select(CheckIn).where(CheckIn.incident_id == incident_id)
            )
        ).all()
        # Latest status per user wins.
        by_user: dict[str, CheckIn] = {}
        for c in check_ins:
            key = c.user_id or c.id
            cur = by_user.get(key)
            if cur is None or c.ts > cur.ts:
                by_user[key] = c

        accounted = sum(1 for c in by_user.values() if CheckInStatus(c.status) in ACCOUNTED_STATUSES)
        needs_help = sum(1 for c in by_user.values() if CheckInStatus(c.status) == CheckInStatus.needs_help)

        unaccounted = max(0, round(total) - accounted)
        zones_with_people = sorted(
            [(z, n) for z, n in per_zone.items() if n > 0], key=lambda x: x[1], reverse=True
        )
        return Accounting(
            incident_id=incident_id,
            occupancy_total=round(total, 2),
            accounted=accounted,
            unaccounted=unaccounted,
            needs_help=needs_help,
            zones_with_people=zones_with_people,
        )

    # --- named-resident roster (the people behind the anonymous counts) ------
    async def _resident_units(self, building_id: str) -> list[tuple[User, Unit | None]]:
        """Every registered resident of the building with their home unit (if any)."""
        rows = (
            await self.session.execute(
                select(User, Unit)
                .join(ResidentUnit, ResidentUnit.user_id == User.id)
                .join(Unit, Unit.id == ResidentUnit.unit_id, isouter=True)
                .where(
                    ResidentUnit.building_id == building_id,
                    User.role == Role.resident.value,
                )
                .order_by(User.display_name)
            )
        ).all()
        # De-dup users that map to more than one unit (keep the first unit).
        seen: dict[str, tuple[User, Unit | None]] = {}
        for user, unit in rows:
            seen.setdefault(user.id, (user, unit))
        return list(seen.values())

    async def building_residents(self, building_id: str) -> list[RosterPerson]:
        """Named residents with no incident context (status 'unknown')."""
        return [
            RosterPerson(
                user_id=u.id,
                display_name=u.display_name or u.username,
                unit_id=unit.id if unit else None,
                unit_label=unit.label if unit else None,
                phone=u.phone,
                status="unknown",
                source=None,
                ts=None,
            )
            for u, unit in await self._resident_units(building_id)
        ]

    async def roster(self, incident_id: str, building_id: str) -> list[RosterPerson]:
        """Named residents enriched with their latest check-in status for an incident."""
        residents = await self._resident_units(building_id)

        check_ins = (
            await self.session.scalars(
                select(CheckIn).where(CheckIn.incident_id == incident_id)
            )
        ).all()
        latest: dict[str, CheckIn] = {}
        for c in check_ins:
            if c.user_id is None:
                continue
            cur = latest.get(c.user_id)
            if cur is None or c.ts > cur.ts:
                latest[c.user_id] = c

        people: list[RosterPerson] = []
        for u, unit in residents:
            ci = latest.get(u.id)
            people.append(
                RosterPerson(
                    user_id=u.id,
                    display_name=u.display_name or u.username,
                    unit_id=unit.id if unit else None,
                    unit_label=unit.label if unit else None,
                    phone=u.phone,
                    status=ci.status if ci else "unknown",
                    source=ci.source if ci else None,
                    ts=ci.ts if ci else None,
                )
            )
        # Surface the people who need attention first: needs_help, then awaiting, then safe.
        order = {"needs_help": 0, "no_response": 1, "unknown": 2, "safe_inside": 3, "safe_outside": 4}
        people.sort(key=lambda p: (order.get(p.status, 2), p.display_name))
        return people

    @staticmethod
    def roster_summary(people: list[RosterPerson]) -> tuple[int, int, int]:
        """(safe, needs_help, awaiting) counts. 'awaiting' = unknown / no_response."""
        safe_values = {s.value for s in _SAFE_STATUSES}
        safe = sum(1 for p in people if p.status in safe_values)
        needs_help = sum(1 for p in people if p.status == CheckInStatus.needs_help.value)
        awaiting = len(people) - safe - needs_help
        return safe, needs_help, awaiting
