"""Household invites: hash-only codes, single use, expiry, 404 sameness, roles, care-profile
take-over with consent, membership, leaving, and the hourly attempt ceiling."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select, text, update

from app.db import SessionLocal
from app.models import AuditLogEntry, CareProfile, HouseholdInvite, HouseholdInviteAttempt, ResidentUnit, User
from tests.conftest import auth_token

INVITES = "/api/v1/me/household/invites"
NOTE = "Concentrator de oxigen in dormitorul din spate"
CREATED_KEYS = {"id", "code", "url", "app_url", "unit_id", "unit_label", "care_profile_id", "expires_ts"}
PREVIEW_KEYS = {"building_name", "unit_label", "floor_label", "inviter_name", "has_care_profile",
                "care_profile_name", "expires_ts"}


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _new_resident(username: str) -> None:
    """A resident with an account but no unit yet (the invitee)."""
    async with SessionLocal() as s:
        s.add(User(id=f"usr_{username}", username=username, display_name=username.title(), role="resident"))
        await s.commit()


async def _invite(client, user: str = "ana", **body) -> dict:
    resp = await client.post(INVITES, json={"unit_id": "unit_0312", **body}, headers=await _hdr(client, user))
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _grandma(client) -> dict:
    resp = await client.post("/api/v1/me/care-profiles", headers=await _hdr(client, "ana"), json={
        "unit_id": "unit_0312", "display_name": "Bunica Maria", "is_self": False, "needs": ["wheelchair"],
        "note": NOTE, "consent": True})
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _audit(prefix: str) -> list[AuditLogEntry]:
    async with SessionLocal() as s:
        return list((await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action.like(f"{prefix}%")))).all())


async def test_create_list_revoke_store_only_the_hash(client):
    ana, ioana = await _hdr(client, "ana"), await _hdr(client, "ioana")
    invite = await _invite(client)
    assert set(invite) == CREATED_KEYS and len(invite["code"]) >= 20
    assert invite["url"] == f"http://localhost/join/{invite['code']}"
    assert invite["app_url"] == f"canary://join/{invite['code']}"
    expires = datetime.fromisoformat(invite["expires_ts"].replace("Z", "+00:00"))
    assert timedelta(hours=71) < expires - datetime.now(timezone.utc) <= timedelta(hours=72)

    async with SessionLocal() as s:
        row = await s.get(HouseholdInvite, invite["id"])
        raw = json.dumps([[str(v) for v in r] for r in (await s.execute(text("SELECT * FROM household_invites"))).all()])
    assert row.code_hash == hashlib.sha256(invite["code"].encode()).hexdigest()
    assert invite["code"] not in raw

    [listed] = (await client.get(INVITES, headers=ana)).json()
    assert listed == {"id": invite["id"], "unit_id": "unit_0312", "unit_label": "Ap. 12", "care_profile_id": None,
                      "care_profile_name": None, "created_ts": listed["created_ts"], "expires_ts": invite["expires_ts"]}
    assert (await client.get(INVITES, headers=ioana)).json() == []

    for body, code in (({"unit_id": "unit_0313"}, 404), ({"unit_id": "common"}, 404),
                       ({"unit_id": "unit_0312", "care_profile_id": "nope"}, 404)):
        assert (await client.post(INVITES, json=body, headers=ana)).status_code == code, body
    me = await client.post("/api/v1/me/care-profiles", headers=ana, json={
        "unit_id": "unit_0312", "display_name": "Ana", "is_self": True, "needs": ["hearing_impaired"], "consent": True})
    resp = await client.post(INVITES, json={"unit_id": "unit_0312", "care_profile_id": me.json()["id"]}, headers=ana)
    assert resp.status_code == 422
    resp = await client.post(INVITES, json={"unit_id": "unit_0312", "care_profile_id": me.json()["id"]}, headers=ioana)
    assert resp.status_code == 404  # not ioana's profile

    for _ in range(4):
        await _invite(client, "ioana")  # 5 pending for the unit, whoever invited
    assert (await client.post(INVITES, json={"unit_id": "unit_0312"}, headers=ana)).status_code == 409

    assert (await client.delete(f"{INVITES}/{invite['id']}", headers=ioana)).status_code == 404  # owner only
    assert (await client.delete(f"{INVITES}/{invite['id']}", headers=ana)).status_code == 204
    assert (await client.delete(f"{INVITES}/{invite['id']}", headers=ana)).status_code == 404
    assert (await client.get(INVITES, headers=ana)).json() == []
    await _invite(client)  # the revoked one freed a slot

    audit = await _audit("household_invite")
    assert sorted({a.action for a in audit}) == ["household_invite_created", "household_invite_revoked"]
    assert invite["code"] not in json.dumps([[a.target, a.detail] for a in audit])


async def test_preview_never_shows_needs_and_dead_codes_look_alike(client):
    await _new_resident("dan")
    dan = await _hdr(client, "dan")
    grandma = await _grandma(client)
    invite = await _invite(client, care_profile_id=grandma["id"])

    resp = await client.get(f"/api/v1/household/invites/{invite['code']}", headers=dan)
    assert resp.status_code == 200, resp.text
    preview = resp.json()
    assert set(preview) == PREVIEW_KEYS
    assert (preview["building_name"], preview["unit_label"], preview["floor_label"], preview["inviter_name"],
            preview["has_care_profile"], preview["care_profile_name"]) == (
        "Demo", "Ap. 12", "Etaj 3", "Ana Popescu", True, "Bunica Maria")
    assert NOTE not in resp.text and "wheelchair" not in resp.text
    assert (await client.get(f"/api/v1/household/invites/{invite['code']}",
                             headers=await _hdr(client, "mihai"))).status_code == 200  # any authenticated user

    unknown = await client.get("/api/v1/household/invites/not-a-real-code", headers=dan)
    expired, revoked, used = await _invite(client), await _invite(client), await _invite(client)
    async with SessionLocal() as s:
        await s.execute(update(HouseholdInvite).where(HouseholdInvite.id == expired["id"])
                        .values(expires_ts=datetime.now(timezone.utc) - timedelta(minutes=1)))
        await s.commit()
    await client.delete(f"{INVITES}/{revoked['id']}", headers=await _hdr(client, "ana"))
    await client.post(f"/api/v1/household/invites/{used['code']}/accept", json={}, headers=dan)
    for dead in (expired, revoked, used):
        resp = await client.get(f"/api/v1/household/invites/{dead['code']}", headers=dan)
        assert (resp.status_code, resp.json()) == (unknown.status_code, unknown.json()) == (404, unknown.json())
        resp = await client.post(f"/api/v1/household/invites/{dead['code']}/accept", json={}, headers=dan)
        assert (resp.status_code, resp.json()) == (404, unknown.json())


async def test_accept_roles_single_use_and_already_member(client):
    await _new_resident("dan")
    dan, ana, ioana = await _hdr(client, "dan"), await _hdr(client, "ana"), await _hdr(client, "ioana")
    grandma = await _grandma(client)
    invite = await _invite(client, care_profile_id=grandma["id"])
    accept = f"/api/v1/household/invites/{invite['code']}/accept"

    for staff in ("mihai", "dispecer", "admin"):
        assert (await client.post(accept, json={}, headers=await _hdr(client, staff))).status_code == 403, staff
    assert (await client.post(accept, json={}, headers=ana)).status_code == 409  # the inviter
    for body in ({"take_over_care_profile": True}, {"take_over_care_profile": True, "consent": False},
                 {"take_over_care_profile": True, "consent": 1}):
        assert (await client.post(accept, json=body, headers=dan)).status_code == 422, body

    resp = await client.post(accept, json={"take_over_care_profile": False, "consent": False}, headers=dan)
    assert (resp.status_code, resp.json()) == (200, {"unit_id": "unit_0312", "unit_label": "Ap. 12",
                                                     "building_id": "bld_007", "care_profile_id": None})
    assert [u["unit_id"] for u in (await client.get("/api/v1/me", headers=dan)).json()["units"]] == ["unit_0312"]
    assert grandma["id"] in [p["id"] for p in (await client.get("/api/v1/me/care-profiles", headers=ana)).json()]
    assert (await client.post(accept, json={}, headers=dan)).status_code == 404  # single use

    # an existing member accepting still consumes the invite, without a second membership
    second = await _invite(client)
    resp = await client.post(f"/api/v1/household/invites/{second['code']}/accept", json={}, headers=ioana)
    assert resp.status_code == 200
    assert (await client.get(f"/api/v1/household/invites/{second['code']}", headers=dan)).status_code == 404
    async with SessionLocal() as s:
        assert await s.scalar(select(func.count()).select_from(ResidentUnit).where(
            ResidentUnit.user_id == "usr_ioana", ResidentUnit.unit_id == "unit_0312")) == 1
    accepted = [a.detail for a in await _audit("household_invite_accepted")]
    assert accepted == [{"already_member": False, "care_profile_transferred": False},
                        {"already_member": True, "care_profile_transferred": False}]


async def test_care_profile_take_over_needs_consent_and_no_own_profile(client):
    await _new_resident("maria")
    maria, radu = await _hdr(client, "maria"), await _hdr(client, "radu")
    grandma = await _grandma(client)
    invite = await _invite(client, care_profile_id=grandma["id"])
    accept = f"/api/v1/household/invites/{invite['code']}/accept"
    take_over = {"take_over_care_profile": True, "consent": True}

    # radu already has his own profile: refused, and the invite stays usable
    await client.post("/api/v1/me/care-profiles", headers=radu, json={
        "unit_id": "unit_0313", "display_name": "Radu", "is_self": True, "needs": ["pet"], "consent": True})
    resp = await client.post(accept, json=take_over, headers=radu)
    assert resp.status_code == 409 and "care profile" in resp.json()["detail"]
    assert (await client.get(f"/api/v1/household/invites/{invite['code']}", headers=maria)).status_code == 200

    resp = await client.post(accept, json=take_over, headers=maria)
    assert (resp.status_code, resp.json()["care_profile_id"]) == (200, grandma["id"])
    [mine] = (await client.get("/api/v1/me/care-profiles", headers=maria)).json()
    assert (mine["id"], mine["is_self"], mine["needs"], mine["note"]) == (grandma["id"], True, ["wheelchair"], NOTE)
    assert mine["consent_ts"] > grandma["consent_ts"]
    ana_profiles = (await client.get("/api/v1/me/care-profiles", headers=await _hdr(client, "ana"))).json()
    assert grandma["id"] not in [p["id"] for p in ana_profiles]
    async with SessionLocal() as s:
        profile = await s.get(CareProfile, grandma["id"])
    assert (profile.owner_user_id, profile.person_user_id) == ("usr_maria", "usr_maria")
    [transfer] = await _audit("care_profile_transferred")
    assert (transfer.actor, transfer.target, transfer.detail) == ("usr_maria", grandma["id"], {"from_user": "usr_ana"})
    dump = json.dumps([[a.target, a.detail] for a in await _audit("")])
    assert "Bunica" not in dump and NOTE not in dump and invite["code"] not in dump


async def test_members_and_leaving(client):
    await _new_resident("dan")
    dan, ana = await _hdr(client, "dan"), await _hdr(client, "ana")
    [unit] = (await client.get("/api/v1/me/household", headers=ana)).json()
    assert (unit["unit_id"], unit["unit_label"]) == ("unit_0312", "Ap. 12")
    assert {(m["display_name"], m["is_me"], m["since"]) for m in unit["members"]} == {
        ("Ana Popescu", True, None), ("Ioana Popescu", False, None)}
    assert all(set(m) == {"user_id", "display_name", "is_me", "since"} for m in unit["members"])

    invite = await _invite(client)
    await client.post(f"/api/v1/household/invites/{invite['code']}/accept", json={}, headers=dan)
    [unit] = (await client.get("/api/v1/me/household", headers=ana)).json()
    joined = next(m for m in unit["members"] if m["user_id"] == "usr_dan")
    assert joined["since"] is not None and joined["is_me"] is False

    assert (await client.delete("/api/v1/me/household/unit_0312", headers=dan)).status_code == 204
    assert (await client.get("/api/v1/me", headers=dan)).json()["units"] == []
    assert (await client.delete("/api/v1/me/household/unit_0312", headers=dan)).status_code == 404
    assert "usr_dan" not in [m["user_id"] for m in (await client.get("/api/v1/me/household", headers=ana)).json()[0]
                             ["members"]]

    # leaving takes the leaver's care profiles and pending invites for that unit with them
    grandma = await _grandma(client)
    pending = await _invite(client)
    assert (await client.delete("/api/v1/me/household/unit_0312", headers=ana)).status_code == 204
    async with SessionLocal() as s:
        assert await s.get(CareProfile, grandma["id"]) is None
        assert (await s.get(HouseholdInvite, pending["id"])).revoked_ts is not None
        assert await s.scalar(select(func.count()).select_from(ResidentUnit).where(
            ResidentUnit.user_id == "usr_ioana", ResidentUnit.unit_id == "unit_0312")) == 1
    actions = [a.action for a in await _audit("") if a.actor == "usr_ana"]
    assert "household_left" in actions and "care_profile_deleted" in actions


async def test_preview_and_accept_attempts_are_capped_per_user_per_hour(client):
    await _new_resident("dan")
    dan = await _hdr(client, "dan")
    for _ in range(19):
        assert (await client.get("/api/v1/household/invites/guess", headers=dan)).status_code == 404
    assert (await client.post("/api/v1/household/invites/guess/accept", json={}, headers=dan)).status_code == 404
    assert (await client.get("/api/v1/household/invites/guess", headers=dan)).status_code == 429
    assert (await client.post("/api/v1/household/invites/guess/accept", json={}, headers=dan)).status_code == 429
    invite = await _invite(client)  # even a valid code waits
    assert (await client.get(f"/api/v1/household/invites/{invite['code']}", headers=dan)).status_code == 429
    assert (await client.get(f"/api/v1/household/invites/{invite['code']}",
                             headers=await _hdr(client, "radu"))).status_code == 200  # per user

    async with SessionLocal() as s:  # an hour later the ceiling resets
        await s.execute(update(HouseholdInviteAttempt).values(ts=datetime.now(timezone.utc) - timedelta(hours=2)))
        await s.commit()
    assert (await client.get(f"/api/v1/household/invites/{invite['code']}", headers=dan)).status_code == 200
