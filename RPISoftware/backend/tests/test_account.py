"""Self-service account: GET / PATCH /me (any role), phone normalization, audit."""

from __future__ import annotations

import json

import pytest
from sqlalchemy import select

from app.db import SessionLocal
from app.models import AuditLogEntry
from tests.conftest import auth_token, telemetry

ME = "/api/v1/me"
ME_KEYS = {"user_id", "username", "display_name", "role", "phone", "email", "language", "units"}


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _audit() -> list[AuditLogEntry]:
    async with SessionLocal() as s:
        return list((await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action == "account_updated"))).all())


async def test_get_me_for_a_resident_and_for_staff(client):
    me = (await client.get(ME, headers=await _hdr(client, "ana"))).json()
    assert me == {
        "user_id": "usr_ana", "username": "ana", "display_name": "Ana Popescu", "role": "resident",
        "phone": "+40700000001", "email": "", "language": "ro",
        "units": [{"unit_id": "unit_0312", "unit_label": "Ap. 12", "building_id": "bld_007", "floor_label": "Etaj 3",
                   "kind": "residential"},
                  {"unit_id": "unit_live", "unit_label": "Live", "building_id": "bld_live", "floor_label": "Parter",
                   "kind": "common"}],
    }
    staff = (await client.get(ME, headers=await _hdr(client, "mihai"))).json()
    assert set(staff) == ME_KEYS and (staff["role"], staff["units"]) == ("hoa_manager", [])
    assert (await client.get(ME)).status_code in (401, 403)


@pytest.mark.parametrize(("raw", "stored"), [
    ("0722 123 456", "+40722123456"),
    ("0722-123-456", "+40722123456"),
    ("(0722) 123.456", "+40722123456"),
    ("+40722123456", "+40722123456"),
    ("+40 722 123 456", "+40722123456"),
    ("0040722123456", "+40722123456"),
    ("0213 123 456", "+40213123456"),
    ("+44 20 7946 0958", "+442079460958"),
    ("", ""),
])
async def test_phone_is_normalized_to_e164(client, raw, stored):
    resp = await client.patch(ME, json={"phone": raw}, headers=await _hdr(client, "ana"))
    assert resp.status_code == 200, resp.text
    assert resp.json()["phone"] == stored


async def test_patch_each_field_and_audit_names_only(client):
    ana = await _hdr(client, "ana")
    resp = await client.patch(ME, json={"display_name": "  Ana P.  "}, headers=ana)
    assert (resp.status_code, resp.json()["display_name"]) == (200, "Ana P.")
    resp = await client.patch(ME, json={"email": " ana@example.ro ", "phone": "0722 123 456"}, headers=ana)
    assert (resp.json()["email"], resp.json()["phone"]) == ("ana@example.ro", "+40722123456")
    assert (await client.get(ME, headers=ana)).json()["email"] == "ana@example.ro"
    resp = await client.patch(ME, json={"email": "", "phone": ""}, headers=ana)
    assert (resp.json()["email"], resp.json()["phone"]) == ("", "")
    await client.patch(ME, json={"display_name": "Ana P."}, headers=ana)  # unchanged: not audited

    audit = await _audit()
    assert [(a.actor, a.target, a.detail) for a in audit] == [
        ("usr_ana", "usr_ana", {"fields": ["display_name"]}),
        ("usr_ana", "usr_ana", {"fields": ["phone", "email"]}),
        ("usr_ana", "usr_ana", {"fields": ["phone", "email"]}),
    ]
    dump = json.dumps([a.detail for a in audit])
    assert "Ana P." not in dump and "example.ro" not in dump and "722" not in dump


async def test_invalid_values_and_locked_fields_are_refused(client):
    ana = await _hdr(client, "ana")
    bad = [
        {"display_name": ""}, {"display_name": "   "}, {"display_name": "x" * 61},
        {"phone": "722123456"}, {"phone": "07221234567"}, {"phone": "+4072212345"}, {"phone": "0722 abc 456"},
        {"phone": "+0722123456"}, {"phone": "123"}, {"phone": None},
        {"email": "ana"}, {"email": "ana@example"}, {"email": "a@@example.ro"}, {"email": "a b@example.ro"},
        {"email": "x" * 250 + "@a.ro"}, {"email": None},
        {"username": "boss"}, {"role": "hoa_manager"}, {"display_name": "Ana", "role": "system_admin"},
    ]
    for body in bad:
        resp = await client.patch(ME, json=body, headers=ana)
        assert resp.status_code == 422, body
    detail = (await client.patch(ME, json={"phone": "12"}, headers=ana)).json()["detail"]
    assert "0722 123 456" in json.dumps(detail)  # tells the user what is accepted
    me = (await client.get(ME, headers=ana)).json()
    assert (me["username"], me["role"], me["display_name"], me["phone"]) == ("ana", "resident", "Ana Popescu",
                                                                             "+40700000001")
    assert await _audit() == []


async def test_roster_contacts_follow_the_updated_phone(client):
    ana = await _hdr(client, "ana")
    resp = await client.post("/api/v1/me/care-profiles", headers=ana, json={
        "unit_id": "unit_0312", "display_name": "Bunica", "is_self": False, "needs": ["wheelchair"], "note": None,
        "consent": True})
    assert resp.status_code == 201, resp.text
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    mihai = await _hdr(client, "mihai")
    [incident] = (await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True},
                                   headers=mihai)).json()

    await client.patch(ME, json={"phone": "0744 555 666"}, headers=ana)
    roster = (await client.get(f"/api/v1/incidents/{incident['id']}/roster", headers=mihai)).json()
    assert roster["priority"][0]["contact_phone"] == "+40744555666"
    assert next(e for e in roster["entries"] if e["user_id"] == "usr_ana")["phone"] == "+40744555666"
