"""Household invites: a resident invites someone with their own account to join their unit
(docs/HARDWARE.md section 4, "Household invites").

The invite code is shown once, at creation; the hub stores only its SHA-256. Codes are single
use and expire after 72 h; unknown, expired, used and revoked codes all answer the same 404.
Preview + accept calls are capped per user per hour. Audit entries carry ids only, never the
code, names, needs or notes.
"""

from __future__ import annotations

import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.care import service as care
from app.config import settings
from app.db import get_session
from app.enums import Role
from app.models import (
    AuditLogEntry,
    Building,
    CareCheckIn,
    CareProfile,
    Floor,
    HouseholdInvite,
    HouseholdInviteAttempt,
    ResidentUnit,
    Unit,
    User,
)
from app.schemas import (
    HouseholdInviteCreated,
    HouseholdInviteIn,
    HouseholdInviteOut,
    HouseholdMemberOut,
    HouseholdOut,
    InviteAcceptIn,
    InviteAcceptOut,
    InvitePreviewOut,
)
from app.security import Principal, get_current_principal, require_roles

router = APIRouter(prefix="/api/v1", tags=["household"])

INVITE_TTL = timedelta(hours=72)
MAX_PENDING_PER_UNIT = 5
ATTEMPTS_PER_HOUR = 20  # preview + accept calls per user


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _hash(code: str) -> str:
    return hashlib.sha256(code.encode()).hexdigest()


def _audit(actor: str, action: str, target: str, **detail) -> AuditLogEntry:
    return AuditLogEntry(actor=actor, action=action, target=target, detail=detail)


def _pending(now: datetime):
    return (HouseholdInvite.used_ts.is_(None), HouseholdInvite.revoked_ts.is_(None), HouseholdInvite.expires_ts > now)


def _profile_name(profile: CareProfile | None) -> str | None:
    if profile is None:
        return None
    try:
        return care.unseal(profile).display_name
    except care.CareUnavailable:  # no key: the invite still works, just without the name
        return None


async def _count_attempt(session: AsyncSession, principal: Principal) -> None:
    """429 past ATTEMPTS_PER_HOUR preview/accept calls in the last hour (refused calls don't count)."""
    hour_ago = _now() - timedelta(hours=1)
    await session.execute(
        delete(HouseholdInviteAttempt).where(
            HouseholdInviteAttempt.user_id == principal.user_id, HouseholdInviteAttempt.ts < hour_ago
        )
    )
    recent = await session.scalar(
        select(func.count()).select_from(HouseholdInviteAttempt).where(
            HouseholdInviteAttempt.user_id == principal.user_id
        )
    )
    if recent >= ATTEMPTS_PER_HOUR:
        await session.commit()
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "too many invite attempts; try again in an hour")
    session.add(HouseholdInviteAttempt(user_id=principal.user_id))
    await session.commit()


async def _live_invite(session: AsyncSession, code: str) -> HouseholdInvite:
    invite = await session.scalar(select(HouseholdInvite).where(HouseholdInvite.code_hash == _hash(code)))
    if invite is None or invite.used_ts or invite.revoked_ts or invite.expires_ts <= _now():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "invite not found")  # one answer: no oracle
    return invite


async def _invite_profile(session: AsyncSession, invite: HouseholdInvite) -> CareProfile | None:
    """The invite's care profile if it still exists, is still the inviter's and not a self profile."""
    if not invite.care_profile_id:
        return None
    profile = await session.get(CareProfile, invite.care_profile_id)
    if profile is None or profile.owner_user_id != invite.inviter_user_id or profile.person_user_id is not None:
        return None
    return profile


# --------------------------------------------------------------------------- #
# Inviter
# --------------------------------------------------------------------------- #
def invite_url(public_url: str, host_header: str | None, code: str) -> str:
    """The join link: the host the hub was reached on (it changes with the hotspot's subnet, and
    phone browsers cannot open canary-hub.local), with the scheme and dashboard port of
    CANARY_PUBLIC_URL. The app calls port 8000 directly, so the request's own port is dropped."""
    base = public_url.rstrip("/")
    if not host_header:
        return f"{base}/join/{code}"
    parts = urlsplit(base)
    host = host_header.strip()
    if host.startswith("["):  # IPv6 literal, maybe with a port
        host = host[: host.index("]") + 1]
    else:
        host = host.split(":", 1)[0]
    port = f":{parts.port}" if parts.port else ""
    return f"{parts.scheme}://{host}{port}/join/{code}"


@router.post("/me/household/invites", response_model=HouseholdInviteCreated, status_code=status.HTTP_201_CREATED)
async def create_invite(
    req: HouseholdInviteIn,
    request: Request,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> HouseholdInviteCreated:
    unit = await care.residential_unit(session, principal.user_id, req.unit_id)
    if unit is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unit not found")
    if req.care_profile_id is not None:
        profile = await session.get(CareProfile, req.care_profile_id)
        if profile is None or profile.owner_user_id != principal.user_id or profile.unit_id != unit.id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "care profile not found")
        if profile.person_user_id is not None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "an is_self profile cannot be handed over")
    now = _now()
    pending = await session.scalar(
        select(func.count()).select_from(HouseholdInvite).where(HouseholdInvite.unit_id == unit.id, *_pending(now))
    )
    if pending >= MAX_PENDING_PER_UNIT:
        raise HTTPException(status.HTTP_409_CONFLICT, f"at most {MAX_PENDING_PER_UNIT} pending invites per unit")
    code = secrets.token_urlsafe(16)
    invite = HouseholdInvite(
        code_hash=_hash(code), building_id=unit.building_id, unit_id=unit.id, inviter_user_id=principal.user_id,
        care_profile_id=req.care_profile_id, created_ts=now, expires_ts=now + INVITE_TTL,
    )
    session.add(invite)
    await session.flush()
    session.add(_audit(principal.user_id, "household_invite_created", invite.id,
                       with_care_profile=req.care_profile_id is not None))
    await session.commit()
    return HouseholdInviteCreated(
        id=invite.id, code=code, url=invite_url(settings.public_url, request.headers.get("host"), code), app_url=f"canary://join/{code}",
        unit_id=unit.id, unit_label=unit.label, care_profile_id=invite.care_profile_id, expires_ts=invite.expires_ts,
    )


@router.get("/me/household/invites", response_model=list[HouseholdInviteOut])
async def my_invites(
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> list[HouseholdInviteOut]:
    rows = await session.execute(
        select(HouseholdInvite, Unit.label)
        .join(Unit, Unit.id == HouseholdInvite.unit_id)
        .where(HouseholdInvite.inviter_user_id == principal.user_id, *_pending(_now()))
        .order_by(HouseholdInvite.created_ts, HouseholdInvite.id)
    )
    out = []
    for invite, unit_label in rows.all():
        profile = await _invite_profile(session, invite)
        out.append(HouseholdInviteOut(
            id=invite.id, unit_id=invite.unit_id, unit_label=unit_label, care_profile_id=invite.care_profile_id,
            care_profile_name=_profile_name(profile), created_ts=invite.created_ts, expires_ts=invite.expires_ts,
        ))
    return out


@router.delete("/me/household/invites/{invite_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_invite(
    invite_id: str,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> Response:
    invite = await session.get(HouseholdInvite, invite_id)
    if invite is None or invite.inviter_user_id != principal.user_id or invite.used_ts or invite.revoked_ts:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "invite not found")
    invite.revoked_ts = _now()
    session.add(_audit(principal.user_id, "household_invite_revoked", invite.id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------- #
# Invitee
# --------------------------------------------------------------------------- #
@router.get("/household/invites/{code}", response_model=InvitePreviewOut)
async def preview_invite(
    code: str,
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> InvitePreviewOut:
    """What the invite is for, before accepting. Never needs or notes."""
    await _count_attempt(session, principal)
    invite = await _live_invite(session, code)
    unit = await session.get(Unit, invite.unit_id)
    building = await session.get(Building, invite.building_id)
    floor = await session.get(Floor, unit.floor_id) if unit else None
    inviter = await session.get(User, invite.inviter_user_id)
    profile = await _invite_profile(session, invite)
    return InvitePreviewOut(
        building_name=building.name if building else "", unit_label=unit.label if unit else "",
        floor_label=floor.label if floor else None,
        inviter_name=(inviter.display_name or inviter.username) if inviter else "",
        has_care_profile=profile is not None, care_profile_name=_profile_name(profile), expires_ts=invite.expires_ts,
    )


@router.post("/household/invites/{code}/accept", response_model=InviteAcceptOut)
async def accept_invite(
    code: str,
    req: InviteAcceptIn,
    principal: Principal = Depends(get_current_principal),
    session: AsyncSession = Depends(get_session),
) -> InviteAcceptOut:
    if principal.role != Role.resident:  # staff (admins included) never join a household
        raise HTTPException(status.HTTP_403_FORBIDDEN, "only residents can join a household")
    await _count_attempt(session, principal)
    invite = await _live_invite(session, code)
    if invite.inviter_user_id == principal.user_id:
        raise HTTPException(status.HTTP_409_CONFLICT, "you cannot accept your own invite")
    profile = await _invite_profile(session, invite) if req.take_over_care_profile else None
    if profile is not None:
        own = await session.scalar(select(CareProfile.id).where(CareProfile.person_user_id == principal.user_id))
        if own is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, "you already have a care profile for yourself; delete "
                                "it before taking over this one (the invite stays valid)")
    now = _now()
    member = await session.scalar(
        select(ResidentUnit.id).where(ResidentUnit.user_id == principal.user_id, ResidentUnit.unit_id == invite.unit_id)
    )
    if member is None:
        session.add(ResidentUnit(user_id=principal.user_id, unit_id=invite.unit_id, building_id=invite.building_id))
    if profile is not None:
        profile.owner_user_id = profile.person_user_id = principal.user_id
        profile.consent_ts = profile.updated_ts = now
        session.add(_audit(principal.user_id, "care_profile_transferred", profile.id, from_user=invite.inviter_user_id))
    invite.used_ts, invite.used_by_user_id = now, principal.user_id
    session.add(_audit(principal.user_id, "household_invite_accepted", invite.id, already_member=member is not None,
                       care_profile_transferred=profile is not None))
    try:
        await session.commit()
    except IntegrityError as exc:  # a self profile created concurrently
        await session.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "you already have a care profile for yourself") from exc
    unit = await session.get(Unit, invite.unit_id)
    return InviteAcceptOut(unit_id=invite.unit_id, unit_label=unit.label if unit else "",
                           building_id=invite.building_id, care_profile_id=profile.id if profile else None)


# --------------------------------------------------------------------------- #
# Members
# --------------------------------------------------------------------------- #
async def _my_residential_units(session: AsyncSession, principal: Principal) -> list[Unit]:
    return list(
        (
            await session.scalars(
                select(Unit)
                .join(ResidentUnit, ResidentUnit.unit_id == Unit.id)
                .where(ResidentUnit.user_id == principal.user_id, Unit.kind == "residential")
                .order_by(Unit.building_id, Unit.label, Unit.id)
            )
        ).all()
    )


@router.get("/me/household", response_model=list[HouseholdOut])
async def my_household(
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> list[HouseholdOut]:
    """Co-residents of the caller's residential units: names only."""
    out = []
    for unit in await _my_residential_units(session, principal):
        users = (
            await session.scalars(
                select(User).join(ResidentUnit, ResidentUnit.user_id == User.id)
                .where(ResidentUnit.unit_id == unit.id).order_by(User.display_name, User.id)
            )
        ).all()
        joined = dict(
            (
                await session.execute(
                    select(HouseholdInvite.used_by_user_id, func.max(HouseholdInvite.used_ts))
                    .where(HouseholdInvite.unit_id == unit.id, HouseholdInvite.used_ts.is_not(None))
                    .group_by(HouseholdInvite.used_by_user_id)
                )
            ).all()
        )
        members = [
            HouseholdMemberOut(user_id=u.id, display_name=u.display_name or u.username, is_me=u.id == principal.user_id,
                               since=joined.get(u.id))
            for u in dict.fromkeys(users)
        ]
        out.append(HouseholdOut(unit_id=unit.id, unit_label=unit.label, members=members))
    return out


@router.delete("/me/household/{unit_id}", status_code=status.HTTP_204_NO_CONTENT)
async def leave_household(
    unit_id: str,
    principal: Principal = Depends(require_roles(Role.resident)),
    session: AsyncSession = Depends(get_session),
) -> Response:
    """Leave a unit: the caller's membership, their care profiles there (with check-ins) and their
    pending invites for it go; everyone else's stays."""
    if unit_id not in {u.id for u in await _my_residential_units(session, principal)}:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "unit not found")
    profiles = (
        await session.scalars(
            select(CareProfile).where(CareProfile.owner_user_id == principal.user_id, CareProfile.unit_id == unit_id)
        )
    ).all()
    for profile in profiles:
        await session.execute(delete(CareCheckIn).where(CareCheckIn.care_profile_id == profile.id))
        await session.delete(profile)
        session.add(_audit(principal.user_id, "care_profile_deleted", profile.id, reason="household_left"))
    now = _now()
    for invite in (
        await session.scalars(
            select(HouseholdInvite).where(HouseholdInvite.inviter_user_id == principal.user_id,
                                          HouseholdInvite.unit_id == unit_id, *_pending(now))
        )
    ).all():
        invite.revoked_ts = now
        session.add(_audit(principal.user_id, "household_invite_revoked", invite.id, reason="household_left"))
    await session.execute(
        delete(ResidentUnit).where(ResidentUnit.user_id == principal.user_id, ResidentUnit.unit_id == unit_id)
    )
    session.add(_audit(principal.user_id, "household_left", unit_id))
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
