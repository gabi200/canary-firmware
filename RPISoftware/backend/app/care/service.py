"""Care profiles: people who may not evacuate alone (GDPR art. 9 health data).

The display name, needs and note are stored as Fernet tokens under CANARY_CARE_KEY.
Their details leave the hub only through the incident roster, only while the incident
is open, and every such read is audited (docs/HARDWARE.md section 4).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.enums import OPEN_INCIDENT_STATES, IncidentState
from app.models import CareCheckIn, CareProfile, CheckIn, Floor, Incident, ResidentUnit, Unit, User
from app.schemas import CareProfileIn, CareProfileOut, PriorityPersonOut

log = logging.getLogger("canary.care")

# same order as the incident roster: who needs attention first
_ORDER = {"needs_help": 0, "no_response": 1, "unknown": 2, "safe_inside": 3, "safe_outside": 4}
_SAFE = ("safe_inside", "safe_outside")


class CareUnavailable(RuntimeError):
    """CANARY_CARE_KEY is missing, malformed, or does not open the stored profiles (-> 503)."""


@lru_cache(maxsize=4)
def _fernet(key: str) -> Fernet:
    return Fernet(key)


def cipher() -> Fernet:
    key = settings.care_key.strip()
    if not key:
        raise CareUnavailable("care profiles are disabled: CANARY_CARE_KEY is not set (run scripts/pi_setup.sh)")
    try:
        return _fernet(key)
    except ValueError as exc:
        raise CareUnavailable("care profiles are disabled: CANARY_CARE_KEY is not a valid Fernet key") from exc


@dataclass(frozen=True)
class CareDetails:
    display_name: str
    needs: list[str]
    note: str | None


def seal(profile: CareProfile, req: CareProfileIn) -> None:
    """Encrypt the request's name, needs and note into the profile."""
    f = cipher()
    profile.display_name_enc = f.encrypt(req.display_name.encode()).decode()
    profile.needs_enc = f.encrypt(json.dumps([n.value for n in req.needs]).encode()).decode()
    profile.note_enc = f.encrypt(req.note.encode()).decode() if req.note else None


def unseal(profile: CareProfile) -> CareDetails:
    f = cipher()
    try:
        return CareDetails(
            display_name=f.decrypt(profile.display_name_enc.encode()).decode(),
            needs=json.loads(f.decrypt(profile.needs_enc.encode())),
            note=f.decrypt(profile.note_enc.encode()).decode() if profile.note_enc else None,
        )
    except InvalidToken as exc:
        raise CareUnavailable("stored care profiles cannot be decrypted with this CANARY_CARE_KEY") from exc


async def residential_unit(session: AsyncSession, user_id: str, unit_id: str) -> Unit | None:
    """`unit_id` if it is one of the user's residential units (never a common area)."""
    return await session.scalar(
        select(Unit)
        .join(ResidentUnit, ResidentUnit.unit_id == Unit.id)
        .where(ResidentUnit.user_id == user_id, Unit.id == unit_id, Unit.kind == "residential")
    )


async def profile_outs(session: AsyncSession, profiles: list[CareProfile]) -> list[CareProfileOut]:
    rows = await session.execute(select(Unit.id, Unit.label).where(Unit.id.in_({p.unit_id for p in profiles})))
    labels = dict(rows.all())
    outs = []
    for p in profiles:
        d = unseal(p)
        outs.append(
            CareProfileOut(
                id=p.id, unit_id=p.unit_id, unit_label=labels.get(p.unit_id), display_name=d.display_name,
                is_self=p.person_user_id is not None, needs=d.needs, note=d.note, consent_ts=p.consent_ts,
                updated_ts=p.updated_ts,
            )
        )
    return outs


# --------------------------------------------------------------------------- #
# Incident priority list
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class PriorityStatus:
    profile: CareProfile
    status: str  # latest care / self check-in status, else "unknown"
    ts: datetime | None


def is_active(incident: Incident) -> bool:
    return IncidentState(incident.state) in OPEN_INCIDENT_STATES


async def priority_statuses(session: AsyncSession, incident: Incident) -> list[PriorityStatus]:
    """The building's care profiles with their latest status for an open incident: a care
    check-in or, for an is_self profile, the person's own check-in. Empty once closed."""
    if not is_active(incident):
        return []
    profiles = (await session.scalars(select(CareProfile).where(CareProfile.building_id == incident.building_id))).all()
    if not profiles:
        return []
    latest: dict[str, tuple[str, datetime]] = {}

    def offer(profile_id: str, status: str, ts: datetime) -> None:
        if profile_id not in latest or ts > latest[profile_id][1]:
            latest[profile_id] = (status, ts)

    for c in await session.scalars(select(CareCheckIn).where(CareCheckIn.incident_id == incident.id)):
        offer(c.care_profile_id, c.status, c.ts)
    selves = {p.person_user_id: p.id for p in profiles if p.person_user_id}
    if selves:
        own = select(CheckIn).where(CheckIn.incident_id == incident.id, CheckIn.user_id.in_(list(selves)))
        for c in await session.scalars(own):
            offer(selves[c.user_id], c.status, c.ts)
    return [PriorityStatus(p, *latest.get(p.id, ("unknown", None))) for p in profiles]


def awaiting(statuses: list[PriorityStatus]) -> int:
    """Priority people not confirmed safe (needs_help, no_response, unknown)."""
    return sum(1 for s in statuses if s.status not in _SAFE)


async def priority_people(session: AsyncSession, statuses: list[PriorityStatus]) -> list[PriorityPersonOut]:
    """The roster's priority list: needs_help first, then awaiting, then safe; by unit."""
    if not statuses:
        return []
    unit_ids = {s.profile.unit_id for s in statuses}
    units = {u.id: u for u in await session.scalars(select(Unit).where(Unit.id.in_(unit_ids)))}
    floor_ids = {u.floor_id for u in units.values()}
    floors = dict((await session.execute(select(Floor.id, Floor.label).where(Floor.id.in_(floor_ids)))).all())
    owner_ids = {s.profile.owner_user_id for s in statuses}
    owners = {u.id: u for u in await session.scalars(select(User).where(User.id.in_(owner_ids)))}
    people = []
    for s in statuses:
        try:
            d = unseal(s.profile)
        except CareUnavailable:  # still list the person (unit, floor, contact) so nobody is missed
            log.error("care profile %s cannot be decrypted; listed without details", s.profile.id)
            d = CareDetails("", [], None)
        unit, owner = units.get(s.profile.unit_id), owners.get(s.profile.owner_user_id)
        people.append(
            PriorityPersonOut(
                care_profile_id=s.profile.id, display_name=d.display_name, unit_id=s.profile.unit_id,
                unit_label=unit.label if unit else None, floor_label=floors.get(unit.floor_id) if unit else None,
                needs=d.needs, note=d.note, status=s.status, status_ts=s.ts,
                contact_name=(owner.display_name or owner.username) if owner else None,
                contact_phone=owner.phone if owner else None,
            )
        )
    people.sort(key=lambda p: (_ORDER.get(p.status, _ORDER["unknown"]), p.unit_label or "", p.display_name))
    return people
