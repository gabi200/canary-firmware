"""Hub-wide demo/real mode setting."""

from __future__ import annotations

from app.db import SessionLocal
from app.models import Incident
from tests.conftest import auth_token


async def _hdr(client, username):
    return {"Authorization": f"Bearer {await auth_token(client, username)}"}


async def test_mode_defaults_to_real(client):
    r = await client.get("/api/v1/mode", headers=await _hdr(client, "ana"))
    assert r.status_code == 200, r.text
    assert r.json() == {"mode": "real", "building_id": "bld_live", "live_alarm": False}


async def test_manager_switches_mode(client):
    r = await client.put("/api/v1/mode", json={"mode": "demo"}, headers=await _hdr(client, "mihai"))
    assert r.status_code == 200, r.text
    assert r.json()["building_id"] == "bld_007"
    r = await client.get("/api/v1/mode", headers=await _hdr(client, "ana"))
    assert r.json()["mode"] == "demo"


async def test_resident_cannot_switch(client):
    for who in ("ana", "dispecer"):
        r = await client.put("/api/v1/mode", json={"mode": "demo"}, headers=await _hdr(client, who))
        assert r.status_code == 403, who


async def test_bad_mode_rejected(client):
    r = await client.put("/api/v1/mode", json={"mode": "party"}, headers=await _hdr(client, "mihai"))
    assert r.status_code == 422


async def test_live_alarm_reported_in_demo(client):
    hdr = await _hdr(client, "mihai")
    await client.put("/api/v1/mode", json={"mode": "demo"}, headers=hdr)
    async with SessionLocal() as s:
        s.add(Incident(building_id="bld_live", hazard_type="smoke", state="alarm"))
        await s.commit()
    r = await client.get("/api/v1/mode", headers=hdr)
    assert r.json()["live_alarm"] is True
