"""End-to-end safety path over HTTP: detection -> alarm -> evacuation -> victim-accounting."""

from __future__ import annotations

import json

from tests.conftest import auth_token, telemetry


async def _active_incident(client) -> dict:
    resp = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True},
                            headers=await _hdr(client, "mihai"))
    assert resp.status_code == 200, resp.text
    items = resp.json()
    assert items, "expected an active incident"
    return items[0]


async def _hdr(client, username):
    return {"Authorization": f"Bearer {await auth_token(client, username)}"}


async def test_critical_gas_drives_evacuation_and_accounting(client):
    # 1) seed occupancy: 2 in hallway, 1 in bedroom => total 3
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_presence_unit", "wifi_presence", 2, zone_id="zone_hallway", unit_id="common",
        units="persons_est", seq=1))
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_presence_bedroom", "wifi_presence", 1, zone_id="zone_bedroom", unit_id="unit_0312",
        units="persons_est", seq=1))

    # 2) one critical kitchen gas reading -> fast path to evacuation
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    body = r.json()
    assert body["status"] == "accepted"
    assert body["incident_state"] == "evacuation", body
    incident_id = body["incident_id"]

    # 3) event log records the forward ladder
    events = (await client.get(f"/api/v1/incidents/{incident_id}/events",
                               headers=await _hdr(client, "mihai"))).json()
    states = [e["to_state"] for e in events]
    assert states[0] == "detection"
    assert "alarm" in states
    assert states[-1] == "evacuation"

    # 4) accounting before any check-in: 3 present, 0 accounted -> 3 unaccounted
    acc = (await client.get(f"/api/v1/incidents/{incident_id}/accounting",
                            headers=await _hdr(client, "mihai"))).json()
    assert acc["occupancy_total"] == 3
    assert acc["unaccounted"] == 3

    # 5) resident checks in safe -> unaccounted drops to 2
    r = await client.post(f"/api/v1/incidents/{incident_id}/checkin",
                          json={"status": "safe_outside"}, headers=await _hdr(client, "ana"))
    assert r.status_code == 200, r.text
    acc2 = (await client.get(f"/api/v1/incidents/{incident_id}/accounting",
                             headers=await _hdr(client, "mihai"))).json()
    assert acc2["accounted"] == 1
    assert acc2["unaccounted"] == 2


async def test_rbac_resident_cannot_read_accounting(client):
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    incident = await _active_incident(client)
    resp = await client.get(f"/api/v1/incidents/{incident['id']}/accounting",
                            headers=await _hdr(client, "ana"))
    assert resp.status_code == 403


async def test_manager_dismiss_to_false_alarm(client):
    # sub-critical single detection, then manager dismisses
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 1500, zone_id="zone_kitchen", unit_id="unit_0312", seq=1))
    incident = await _active_incident(client)
    assert incident["state"] in ("detection", "verification")
    r = await client.post(f"/api/v1/incidents/{incident['id']}/dismiss",
                          headers=await _hdr(client, "mihai"))
    assert r.status_code == 200
    assert r.json()["state"] == "false_alarm"


async def test_dismiss_evacuating_incident_is_409_not_500(client):
    # Critical gas drives straight to evacuation; dismissing it as a false alarm is an
    # illegal transition. It must return a clean 409 (not crash with a 500, which also
    # strips the CORS headers and surfaces as a CORS error in the browser).
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    incident = await _active_incident(client)
    assert incident["state"] == "evacuation"
    r = await client.post(f"/api/v1/incidents/{incident['id']}/dismiss",
                          headers=await _hdr(client, "mihai"))
    assert r.status_code == 409, r.text
    assert "Resolve" in r.json()["detail"]
    # the incident is untouched — still evacuating, not corrupted
    again = await _active_incident(client)
    assert again["state"] == "evacuation"


async def test_incident_roster_shows_named_residents_and_status(client):
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    incident = await _active_incident(client)

    # before any check-in: everyone present, status unknown
    roster = (await client.get(f"/api/v1/incidents/{incident['id']}/roster",
                               headers=await _hdr(client, "mihai"))).json()
    names = {e["display_name"] for e in roster["entries"]}
    assert "Ana Popescu" in names
    assert roster["total"] >= 4
    assert roster["safe"] == 0 and all(e["status"] == "unknown" for e in roster["entries"])

    # ana checks in safe -> roster reflects it and counts update
    await client.post(f"/api/v1/incidents/{incident['id']}/checkin",
                      json={"status": "safe_outside"}, headers=await _hdr(client, "ana"))
    roster2 = (await client.get(f"/api/v1/incidents/{incident['id']}/roster",
                                headers=await _hdr(client, "mihai"))).json()
    ana = next(e for e in roster2["entries"] if e["display_name"] == "Ana Popescu")
    assert ana["status"] == "safe_outside"
    assert ana["unit_label"] == "Ap. 12"
    assert roster2["safe"] == 1
    assert roster2["awaiting"] == roster2["total"] - 1


async def test_roster_needs_help_sorts_first(client):
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    incident = await _active_incident(client)
    await client.post(f"/api/v1/incidents/{incident['id']}/checkin",
                      json={"status": "needs_help"}, headers=await _hdr(client, "ana"))
    roster = (await client.get(f"/api/v1/incidents/{incident['id']}/roster",
                               headers=await _hdr(client, "mihai"))).json()
    assert roster["needs_help"] == 1
    # the person needing help is surfaced at the top of the list
    assert roster["entries"][0]["status"] == "needs_help"
    assert roster["entries"][0]["display_name"] == "Ana Popescu"


async def test_resident_cannot_read_roster(client):
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=1, edge_state="alarm"))
    incident = await _active_incident(client)
    r = await client.get(f"/api/v1/incidents/{incident['id']}/roster",
                         headers=await _hdr(client, "ana"))
    assert r.status_code == 403


async def test_other_devices_normal_readings_do_not_clear_an_incident(client):
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_co_bedroom", "co", 200, zone_id="zone_bedroom", unit_id="unit_0312", seq=1, edge_state="alarm"))
    assert r.json()["incident_state"] == "evacuation"

    # The boiler-room CO sensor keeps reporting normal: it must not "all clear" an
    # incident whose own source (the bedroom sensor) may have gone silent.
    for seq in range(1, 6):
        await client.post("/api/v1/telemetry", json=telemetry(
            "dev_co_boiler", "co", 3, zone_id="zone_boiler", unit_id="common", seq=seq))
    assert (await _active_incident(client))["state"] == "evacuation"

    # The reporting sensor clearing for the hold window does close it.
    for seq in range(2, 5):
        await client.post("/api/v1/telemetry", json=telemetry(
            "dev_co_bedroom", "co", 3, zone_id="zone_bedroom", unit_id="unit_0312", seq=seq))
    resp = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True},
                            headers=await _hdr(client, "mihai"))
    assert resp.json() == []


async def test_timestamps_are_utc_aware_on_sqlite(client):
    # SQLite drops tzinfo; zone-less timestamps would be read as local time by clients.
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312", edge_state="alarm"))
    incident = await _active_incident(client)
    readings = (await client.get("/api/v1/buildings/bld_007/readings",
                                 headers=await _hdr(client, "mihai"))).json()
    for ts in (incident["opened_ts"], incident["updated_ts"], readings[0]["ts"]):
        assert ts.endswith(("Z", "+00:00")), ts


async def test_an_infinite_reading_still_raises_the_alarm(client):
    # The transition's event payload carries the value; Postgres' json type has no Infinity token.
    body = telemetry("dev_gas_kitchen", "combustible_gas", float("inf"), zone_id="zone_kitchen",
                     unit_id="unit_0312", edge_state="alarm")
    resp = await client.post("/api/v1/telemetry", content=json.dumps(body),  # httpx's json= refuses inf
                             headers={"content-type": "application/json"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["incident_state"] == "evacuation"
