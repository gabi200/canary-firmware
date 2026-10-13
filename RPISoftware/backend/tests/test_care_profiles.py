"""Care profiles (GDPR art. 9 health data): CRUD and validation, encryption at rest, the
incident priority list (open incidents only), check-ins, WebSocket payload, audit."""

from __future__ import annotations

import json

from sqlalchemy import select, text

from app.config import settings
from app.db import SessionLocal
from app.models import AuditLogEntry, Building, CareCheckIn, Floor, ResidentUnit, Unit, User
from app.realtime.ws import manager
from tests.conftest import auth_token, telemetry

GRANDMA = "Bunica Maria"
NOTE = "Concentrator de oxigen in dormitorul din spate"
PROFILE_KEYS = {"id", "unit_id", "unit_label", "display_name", "is_self", "needs", "note", "consent_ts", "updated_ts"}


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


def _body(**overrides) -> dict:
    body = {"unit_id": "unit_0312", "display_name": GRANDMA, "is_self": False,
            "needs": ["wheelchair", "medical_device"], "note": NOTE, "consent": True}
    return {**body, **overrides}


async def _create(client, user: str, **overrides) -> dict:
    resp = await client.post("/api/v1/me/care-profiles", json=_body(**overrides), headers=await _hdr(client, user))
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _open_incident(client) -> dict:
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    resp = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True},
                            headers=await _hdr(client, "mihai"))
    [incident] = resp.json()
    return incident


async def _other_building_resident(client) -> dict:
    async with SessionLocal() as s:
        for row in (
            Building(id="bld_008", name="Bloc B"),
            Floor(id="flr_b1", building_id="bld_008", level=1),
            Unit(id="unit_b11", building_id="bld_008", floor_id="flr_b1", label="Ap. 1"),
            User(id="usr_vlad", username="vlad", role="resident"),
            ResidentUnit(user_id="usr_vlad", unit_id="unit_b11", building_id="bld_008"),
        ):
            s.add(row)
            await s.flush()  # in order: Postgres checks foreign keys, a flush orders by class name
        await s.commit()
    return await _hdr(client, "vlad")


async def _care_audit() -> list[AuditLogEntry]:
    async with SessionLocal() as s:
        rows = await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action.like("care_profile%")))
        return list(rows.all())


async def test_crud_validation_and_owner_only(client):
    ana, ioana, radu = await _hdr(client, "ana"), await _hdr(client, "ioana"), await _hdr(client, "radu")
    url = "/api/v1/me/care-profiles"

    grandma = await _create(client, "ana")
    assert set(grandma) == PROFILE_KEYS
    assert (grandma["unit_label"], grandma["display_name"], grandma["is_self"], grandma["needs"], grandma["note"]) == (
        "Ap. 12", GRANDMA, False, ["wheelchair", "medical_device"], NOTE,
    )
    assert (await client.get(url, headers=ana)).json() == [grandma]

    resp = await client.put(f"{url}/{grandma['id']}", json=_body(needs=["bedridden", "bedridden"], note=None),
                            headers=ana)
    assert resp.status_code == 200, resp.text
    assert (resp.json()["needs"], resp.json()["note"]) == (["bedridden"], None)

    for bad in ({"consent": False}, {"consent": 1}, {"consent": "true"}, {"needs": ["diabetes"]},
                {"needs": [], "note": None}, {"needs": [], "note": "   "}, {"display_name": ""},
                {"display_name": "x" * 61}, {"note": "x" * 281}):
        assert (await client.post(url, json=_body(**bad), headers=ana)).status_code == 422, bad
    missing_consent = {k: v for k, v in _body().items() if k != "consent"}
    assert (await client.post(url, json=missing_consent, headers=ana)).status_code == 422
    for unit_id in ("unit_0313", "common", "nope"):  # radu's flat, a common area, unknown
        assert (await client.post(url, json=_body(unit_id=unit_id), headers=ana)).status_code == 404, unit_id

    me = await _create(client, "ana", display_name="Ana", is_self=True, needs=["hearing_impaired"], note=None)
    assert me["is_self"] is True
    assert (await client.post(url, json=_body(is_self=True), headers=ana)).status_code == 409
    assert (await client.put(f"{url}/{grandma['id']}", json=_body(is_self=True), headers=ana)).status_code == 409
    resp = await client.put(f"{url}/{me['id']}", json=_body(display_name="Ana P.", is_self=True), headers=ana)
    assert resp.status_code == 200 and resp.json()["is_self"] is True

    # another resident of the same flat, another flat, a manager: none of them see or touch ana's profiles
    assert (await client.get(url, headers=ioana)).json() == []
    for headers in (ioana, radu):
        assert (await client.put(f"{url}/{grandma['id']}", json=_body(), headers=headers)).status_code == 404
        assert (await client.delete(f"{url}/{grandma['id']}", headers=headers)).status_code == 404
    assert (await client.get(url, headers=await _hdr(client, "mihai"))).status_code == 403

    assert (await client.delete(f"{url}/{grandma['id']}", headers=ana)).status_code == 204
    assert [p["id"] for p in (await client.get(url, headers=ana)).json()] == [me["id"]]
    assert (await client.delete(f"{url}/{grandma['id']}", headers=ana)).status_code == 404

    # audit: who and which profile, never the content
    audit = await _care_audit()
    assert sorted(a.action for a in audit) == ["care_profile_created", "care_profile_created", "care_profile_deleted",
                                               "care_profile_updated", "care_profile_updated"]
    assert {a.actor for a in audit} == {"usr_ana"} and {a.target for a in audit} == {grandma["id"], me["id"]}
    dump = json.dumps([[a.actor, a.action, a.target, a.detail] for a in audit])
    for secret in (GRANDMA, NOTE, "Ana P.", "bedridden", "hearing_impaired", "wheelchair"):
        assert secret not in dump


async def test_profiles_are_encrypted_at_rest(client):
    created = await _create(client, "ana")
    async with SessionLocal() as s:
        rows = (await s.execute(text("SELECT * FROM care_profiles"))).all()
    raw = json.dumps([[str(v) for v in row] for row in rows])
    assert created["id"] in raw
    for plain in (NOTE, GRANDMA, "wheelchair", "medical_device"):
        assert plain not in raw, plain
    assert (await client.get("/api/v1/me/care-profiles", headers=await _hdr(client, "ana"))).json()[0]["note"] == NOTE


async def test_roster_priority_only_while_the_incident_is_open(client, monkeypatch):
    events: list[dict] = []
    real_broadcast = manager.broadcast

    async def capture(building_id: str, message: dict) -> None:
        events.append(message)
        await real_broadcast(building_id, message)

    monkeypatch.setattr(manager, "broadcast", capture)
    ana, radu, mihai = await _hdr(client, "ana"), await _hdr(client, "radu"), await _hdr(client, "mihai")
    grandma = await _create(client, "ana")
    me = await _create(client, "ana", display_name="Ana", is_self=True, needs=["hearing_impaired"], note=None)
    child = await _create(client, "radu", unit_id="unit_0313", display_name="Andrei", needs=["young_child"],
                          note=None)
    incident = await _open_incident(client)
    roster_url, acc_url = (f"/api/v1/incidents/{incident['id']}/{p}" for p in ("roster", "accounting"))

    roster = (await client.get(roster_url, headers=mihai)).json()
    assert (len(roster["priority"]), roster["priority_awaiting"]) == (3, 3)
    entry = next(p for p in roster["priority"] if p["care_profile_id"] == grandma["id"])
    assert entry == {
        "care_profile_id": grandma["id"], "display_name": GRANDMA, "unit_id": "unit_0312", "unit_label": "Ap. 12",
        "floor_label": "Etaj 3", "needs": ["wheelchair", "medical_device"], "note": NOTE, "status": "unknown",
        "status_ts": None, "contact_name": "Ana Popescu", "contact_phone": "+40700000001",
    }

    # a care check-in, ana's own check-in (her is_self profile), radu for his child
    checkin = f"/api/v1/incidents/{incident['id']}/care-checkin"
    resp = await client.post(checkin, json={"care_profile_id": grandma["id"], "status": "needs_help"}, headers=ana)
    assert (resp.status_code, resp.json()) == (200, {"ok": True})
    await client.post(f"/api/v1/incidents/{incident['id']}/checkin", json={"status": "safe_outside"}, headers=ana)
    await client.post(checkin, json={"care_profile_id": child["id"], "status": "safe_inside"}, headers=radu)

    roster = (await client.get(roster_url, headers=await _hdr(client, "dispecer"))).json()
    assert [(p["care_profile_id"], p["status"]) for p in roster["priority"]] == [
        (grandma["id"], "needs_help"), (child["id"], "safe_inside"), (me["id"], "safe_outside"),
    ]
    assert all(p["status_ts"] for p in roster["priority"]) and roster["priority_awaiting"] == 1
    accounting = (await client.get(acc_url, headers=mihai)).json()
    assert accounting["priority_awaiting"] == 1
    assert not {"priority", "needs", "note", "display_name"} & set(accounting)

    # the WebSocket carries ids and status only
    care_events = [e for e in events if e.get("type") == "care_checkin"]
    assert [set(e) for e in care_events] == [{"type", "incident_id", "building_id", "care_profile_id", "status",
                                              "ts"}] * 2
    dump = json.dumps(care_events)
    assert GRANDMA not in dump and NOTE not in dump and "wheelchair" not in dump and "young_child" not in dump

    # every roster read that showed health data is audited, without the content
    views = [a for a in await _care_audit() if a.action == "care_profile_view"]
    assert [(a.incident_id, a.identity_unlock, a.detail, a.actor) for a in views] == [
        (incident["id"], True, {"count": 3}, "usr_mihai"), (incident["id"], True, {"count": 3}, "usr_disp"),
    ]

    # closed: no health data, no counts, no new view audits, no more check-ins
    assert (await client.post(f"/api/v1/incidents/{incident['id']}/resolve", headers=mihai)).status_code == 200
    roster = (await client.get(roster_url, headers=mihai)).json()
    assert (roster["priority"], roster["priority_awaiting"]) == ([], 0)
    assert (await client.get(acc_url, headers=mihai)).json()["priority_awaiting"] == 0
    assert len([a for a in await _care_audit() if a.action == "care_profile_view"]) == 2
    resp = await client.post(checkin, json={"care_profile_id": grandma["id"], "status": "safe_outside"}, headers=ana)
    assert resp.status_code == 409

    # deleting a profile (withdrawing consent) removes its check-ins too
    assert (await client.delete(f"/api/v1/me/care-profiles/{grandma['id']}", headers=ana)).status_code == 204
    async with SessionLocal() as s:
        left = (await s.scalars(select(CareCheckIn.care_profile_id))).all()
    assert grandma["id"] not in left and child["id"] in left


async def test_care_checkin_is_owner_and_building_only(client):
    grandma = await _create(client, "ana")
    incident = await _open_incident(client)
    url = f"/api/v1/incidents/{incident['id']}/care-checkin"
    body = {"care_profile_id": grandma["id"], "status": "safe_outside"}

    assert (await client.post(url, json=body, headers=await _hdr(client, "ioana"))).status_code == 404  # same flat
    assert (await client.post(url, json=body, headers=await _hdr(client, "radu"))).status_code == 404
    assert (await client.post(url, json=body, headers=await _other_building_resident(client))).status_code == 404
    assert (await client.post(url, json=body, headers=await _hdr(client, "mihai"))).status_code == 403
    ana = await _hdr(client, "ana")
    assert (await client.post(url, json={**body, "care_profile_id": "nope"}, headers=ana)).status_code == 404
    assert (await client.post(url, json={**body, "status": "no_response"}, headers=ana)).status_code == 422
    assert (await client.post(f"/api/v1/incidents/nope/care-checkin", json=body, headers=ana)).status_code == 404
    assert (await client.post(url, json=body, headers=ana)).status_code == 200


async def test_without_the_key_care_endpoints_503_and_the_rest_works(client, monkeypatch):
    grandma = await _create(client, "ana")
    incident = await _open_incident(client)
    ana, mihai = await _hdr(client, "ana"), await _hdr(client, "mihai")

    for key in ("", "not-a-fernet-key"):
        monkeypatch.setattr(settings, "care_key", key)
        resp = await client.get("/api/v1/me/care-profiles", headers=ana)
        assert resp.status_code == 503 and "CANARY_CARE_KEY" in resp.json()["detail"]
        assert (await client.post("/api/v1/me/care-profiles", json=_body(), headers=ana)).status_code == 503
        # the roster still works and still lists the person (unit, floor, contact), without details
        roster = (await client.get(f"/api/v1/incidents/{incident['id']}/roster", headers=mihai)).json()
        [person] = roster["priority"]
        assert (person["unit_label"], person["contact_phone"], person["display_name"], person["needs"]) == (
            "Ap. 12", "+40700000001", "", [],
        )
        assert (await client.get("/api/v1/buildings/bld_007/summary", headers=ana)).status_code == 200

    # withdrawing consent never depends on the key
    assert (await client.delete(f"/api/v1/me/care-profiles/{grandma['id']}", headers=ana)).status_code == 204
