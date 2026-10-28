"""Ingestion under load: receive-time stamping, backlog stats, per-channel isolation, query budget."""

from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import event, func, select

from app.db import SessionLocal, engine
from app.incidents.service import IncidentService
from app.ingestion import broker, hardware
from app.ingestion.hardware import handle_hardware_message
from app.ingestion.mqtt import dispatch
from app.models import DeviceCommand, Node, NodeStatus, SensorReading
from tests.conftest import auth_token
from tests.hardware_docs import air_doc


@pytest.fixture(autouse=True)
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


class _Message:
    def __init__(self, topic: str) -> None:
        self.topic = topic


async def test_queue_stamps_receive_time_and_reports_the_backlog(client, monkeypatch):
    queue = broker.StampedQueue()
    monkeypatch.setattr(broker, "queue", queue)
    assert broker.ingest_stats()["queue"] == 0 and broker.ingest_stats()["lag_s"] == 0.0
    first, second = _Message("a/status"), _Message("b/status")
    queue.put_nowait(first)
    queue.put_nowait(second)
    assert abs(first.received_ts - time.time()) < 1 and second.received_ts >= first.received_ts
    first.received_ts -= 5  # it has been waiting 5 s
    stats = broker.ingest_stats()
    assert stats["queue"] == 2 and 4.9 <= stats["lag_s"] < 7
    assert (await queue.get()) is first

    health = (await client.get("/health")).json()
    assert set(health["ingest"]) == {"connected", "queue", "lag_s"} and health["ingest"]["queue"] == 1


async def test_last_seen_is_the_receive_time_not_the_processing_time(client):
    received = time.time() - 12  # processed 12 s after it arrived
    await dispatch("canary/status", json.dumps(air_doc()).encode(), received_ts=received)
    async with SessionLocal() as s:
        node = await s.get(Node, "canary")
        status_ts = await s.scalar(select(NodeStatus.ts).where(NodeStatus.node_id == "canary"))
        reading_ts = await s.scalar(select(SensorReading.ts).where(SensorReading.device_id == "canary:co"))
    for ts in (node.last_seen_ts, status_ts, reading_ts):
        assert abs(ts.timestamp() - received) < 0.01


async def test_command_results_are_matched_at_their_receive_time(client, monkeypatch):
    class FakeMqtt:
        async def publish(self, *args, **kwargs) -> None:
            pass

    monkeypatch.setattr(broker, "client", FakeMqtt())
    await dispatch("canary/status", json.dumps(air_doc()).encode())
    mihai = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    sent = (await client.post("/api/v1/nodes/canary/commands", json={"command": "TEST"}, headers=mihai)).json()
    async with SessionLocal() as s:  # the command went out 40 s ago; the device answered 3 s later
        row = await s.get(DeviceCommand, sent["command_id"])
        row.sent_ts -= timedelta(seconds=40)
        sent_ts = row.sent_ts
        await s.commit()
    answer = b'{"command":"TEST","accepted":true,"state":"self_test"}'
    await dispatch("canary/command/result", answer, received_ts=sent_ts.timestamp() + 3)  # processed only now
    [item] = (await client.get("/api/v1/nodes/canary/commands", headers=mihai)).json()
    assert (item["status"], item["detail"]) == ("accepted", "self_test")
    result_ts = datetime.fromisoformat(item["result_ts"].replace("Z", "+00:00"))
    assert abs((result_ts - sent_ts).total_seconds() - 3) < 0.01


async def test_one_failing_channel_does_not_lose_the_document_or_the_others(client, monkeypatch):
    real = IncidentService.handle_hazard_reading

    async def flaky(self, **kwargs):
        if kwargs["device_id"].endswith(":co"):
            raise RuntimeError("boom")
        return await real(self, **kwargs)

    monkeypatch.setattr(IncidentService, "handle_hazard_reading", flaky)
    await handle_hardware_message("canary/status", json.dumps(air_doc()).encode())
    async with SessionLocal() as s:
        stored = set((await s.scalars(select(SensorReading.device_id))).all())
        assert await s.scalar(select(func.count()).select_from(NodeStatus)) == 1
        assert (await s.get(Node, "canary")).online is True
    assert stored == {"canary:gas", "canary:particulate", "canary:gas_detector", "canary:presence"}  # co rolled back alone


async def test_a_normal_status_document_stays_within_its_query_budget(client):
    await handle_hardware_message("canary/status", json.dumps(air_doc(uptime_ms=1000)).encode())  # registers
    statements, checkouts = [], []

    def on_execute(conn, cursor, statement, *args):  # noqa: ANN001
        statements.append(statement)

    def on_checkout(*args):  # noqa: ANN001
        checkouts.append(1)

    event.listen(engine.sync_engine, "before_cursor_execute", on_execute)
    event.listen(engine.sync_engine.pool, "checkout", on_checkout)
    try:
        await handle_hardware_message("canary/status", json.dumps(air_doc(uptime_ms=16000)).encode())
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", on_execute)
        event.remove(engine.sync_engine.pool, "checkout", on_checkout)
    # node+zone, node update, status row, device liveness, then per hazard channel: reading + open incident
    assert len(statements) <= 13, statements
    assert len(checkouts) == 1  # one session for the whole document
