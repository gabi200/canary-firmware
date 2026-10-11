"""Per-user language: /me language and notifications built in each recipient's language."""

from __future__ import annotations

from sqlalchemy import select

from app.db import SessionLocal
from app.models import AuditLogEntry, Notification
from app.realtime.ws import manager
from tests.conftest import auth_token, telemetry


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def test_language_defaults_to_romanian_and_is_editable(client):
    ana = await _hdr(client, "ana")
    assert (await client.get("/api/v1/me", headers=ana)).json()["language"] == "ro"
    assert (await client.patch("/api/v1/me", json={"language": "ro"}, headers=ana)).json()["language"] == "ro"
    resp = await client.patch("/api/v1/me", json={"language": "en"}, headers=ana)
    assert (resp.status_code, resp.json()["language"]) == (200, "en")
    assert (await client.get("/api/v1/me", headers=ana)).json()["language"] == "en"
    for bad in ("de", "EN", "", None, 1):
        assert (await client.patch("/api/v1/me", json={"language": bad}, headers=ana)).status_code == 422, bad
    staff = await client.patch("/api/v1/me", json={"language": "en"}, headers=await _hdr(client, "dispecer"))
    assert staff.json()["language"] == "en"

    async with SessionLocal() as s:  # the unchanged "ro" was not audited; the switch to "en" was, by name only
        audit = (await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action == "account_updated",
                                                             AuditLogEntry.actor == "usr_ana"))).all()
    assert [a.detail for a in audit] == [{"fields": ["language"]}]


async def test_notifications_follow_each_recipients_language(client, monkeypatch):
    events: list[dict] = []
    real_broadcast = manager.broadcast

    async def capture(building_id: str, message: dict) -> None:
        events.append(message)
        await real_broadcast(building_id, message)

    monkeypatch.setattr(manager, "broadcast", capture)
    await client.patch("/api/v1/me", json={"language": "en"}, headers=await _hdr(client, "ana"))
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"), headers={"Accept-Language": "ro"})

    async with SessionLocal() as s:
        rows = (await s.execute(select(Notification.recipient_user_id, Notification.title, Notification.body)
                                .where(Notification.state == "evacuation"))).all()
    by_user = {user: (title, body) for user, title, body in rows if user}
    assert by_user["usr_ana"] == ("EVACUATE NOW — Gas leak",
                                  "Evacuate via the safe route to the assembly point. Check in when safe.")
    romanian = ("EVACUAȚI ACUM — Scurgere de gaz",
                "Evacuați pe traseul sigur până la punctul de adunare. Confirmați în aplicație când sunteți în "
                "siguranță.")
    assert by_user["usr_ioana"] == romanian  # resident push
    assert by_user["usr_mihai"] == romanian  # manager web_push
    # the live WebSocket event stays English for everyone
    assert {e["title"] for e in events if e.get("type") == "incident" and e["state"] == "evacuation"} == {
        "EVACUATE NOW — Gas leak"}
