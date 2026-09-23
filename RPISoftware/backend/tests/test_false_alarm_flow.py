"""End-to-end false-alarm reduction over HTTP."""

from __future__ import annotations

from tests.conftest import auth_token, telemetry


async def _hdr(client, user="mihai"):
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _active(client):
    incs = (await client.get("/api/v1/buildings/bld_007/incidents?active=true",
                             headers=await _hdr(client))).json()
    return incs[0] if incs else None


async def test_single_flat_marginal_sensor_is_held_not_alarmed(client):
    # one sensor sitting just over the detection threshold, flat, three samples.
    # Without false-alarm reduction the 3rd (corroborated-by-count) sample would alarm.
    for seq in (1, 2, 3):
        await client.post("/api/v1/telemetry", json=telemetry(
            "dev_gas_kitchen", "combustible_gas", 1050, zone_id="zone_kitchen",
            unit_id="unit_0312", seq=seq))
    inc = await _active(client)
    assert inc is not None
    assert inc["state"] == "verification"  # held, not escalated to alarm
    assert inc["false_alarm_class"] == "likely_benign"


async def test_two_sensors_sustained_reaches_alarm(client):
    # real cross-sensor corroboration -> genuine -> alarm (not held)
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 1200, zone_id="zone_kitchen", unit_id="unit_0312", seq=1))
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_boiler", "combustible_gas", 1200, zone_id="zone_boiler", unit_id="common", seq=1))
    inc = await _active(client)
    assert inc is not None
    assert inc["state"] == "alarm"


async def test_critical_still_evacuates_despite_benign_history(client):
    # benign-looking flat history, then a critical reading -> never suppressed
    for seq in (1, 2):
        await client.post("/api/v1/telemetry", json=telemetry(
            "dev_gas_kitchen", "combustible_gas", 1050, zone_id="zone_kitchen", unit_id="unit_0312", seq=seq))
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=3, edge_state="alarm"))
    assert r.json()["incident_state"] == "evacuation"
