"""Dedupe + reboot regression (ARCHITECTURE.md section 5).

The idempotency key is (device_id, epoch, seq). A duplicate is dropped; a node
reboot (epoch++ , seq restarts at 0) must NOT be mistaken for a duplicate.
"""

from __future__ import annotations

from tests.conftest import telemetry


async def test_duplicate_is_dropped(client):
    msg = telemetry("dev_gas_kitchen", "combustible_gas", 120, zone_id="zone_kitchen",
                    unit_id="unit_0312", epoch=1, seq=10)
    r1 = await client.post("/api/v1/telemetry", json=msg)
    assert r1.status_code == 200
    assert r1.json()["status"] == "accepted"

    r2 = await client.post("/api/v1/telemetry", json=msg)  # identical (device, epoch, seq)
    assert r2.json()["status"] == "duplicate"


async def test_reboot_epoch_change_is_not_deduped(client):
    # pre-reboot reading at epoch=1, seq=5
    pre = telemetry("dev_gas_kitchen", "combustible_gas", 120, zone_id="zone_kitchen",
                    unit_id="unit_0312", epoch=1, seq=5)
    assert (await client.post("/api/v1/telemetry", json=pre)).json()["status"] == "accepted"

    # node reboots: epoch=2, seq restarts at 0..N. These share seq numbers with epoch 1
    # but must all be accepted, never deduped against the prior epoch.
    for seq in range(0, 4):
        post = telemetry("dev_gas_kitchen", "combustible_gas", 120, zone_id="zone_kitchen",
                         unit_id="unit_0312", epoch=2, seq=seq)
        assert (await client.post("/api/v1/telemetry", json=post)).json()["status"] == "accepted"
