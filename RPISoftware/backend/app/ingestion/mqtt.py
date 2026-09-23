"""MQTT consumer (EMQX). Subscribes to telemetry/event topics and runs the pipeline.

aiomqtt is imported lazily so the rest of the app (and the test suite) imports
cleanly even when the MQTT client / broker is absent. The consumer reconnects with
backoff; a broker outage degrades cloud detection but never the edge-local alarm
(ARCHITECTURE.md section 8, failure mode 3).
"""

from __future__ import annotations

import asyncio
import json
import logging

from app.config import settings
from app.db import SessionLocal
from app.enums import EdgeState
from app.ingestion.pipeline import ingest_telemetry
from app.schemas import TelemetryPayload

log = logging.getLogger("canary.mqtt")


async def _handle_message(topic: str, raw: bytes) -> None:
    parts = topic.split("/")
    kind = parts[-1] if parts else ""
    if kind not in ("telemetry", "event"):
        return  # health / cmd / gateway-status handled elsewhere in later phases
    try:
        data = json.loads(raw)
        payload = TelemetryPayload.model_validate(data)
    except Exception as exc:  # noqa: BLE001 - malformed message: log and drop, do not crash consumer
        log.warning("dropping malformed message on %s: %s", topic, exc)
        return
    # An `event` topic means the edge node already fired its local alarm.
    if kind == "event" and payload.edge_state == EdgeState.normal:
        payload.edge_state = EdgeState.alarm
    async with SessionLocal() as session:
        result = await ingest_telemetry(session, payload)
    if result.incident_state:
        log.info("incident %s -> %s", result.incident_id, result.incident_state)


async def run_mqtt_consumer(stop: asyncio.Event) -> None:
    import aiomqtt  # lazy import

    topic = f"{settings.mqtt_topic_prefix}/#"
    backoff = 1.0
    while not stop.is_set():
        try:
            async with aiomqtt.Client(
                hostname=settings.mqtt_host,
                port=settings.mqtt_port,
                username=settings.mqtt_username,
                password=settings.mqtt_password,
            ) as client:
                await client.subscribe(topic)
                log.info("MQTT consumer subscribed to %s", topic)
                backoff = 1.0
                async for message in client.messages:
                    await _handle_message(str(message.topic), bytes(message.payload))
                    if stop.is_set():
                        break
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - reconnect on any broker/network error
            log.warning("MQTT consumer error (%s); reconnecting in %.0fs", exc, backoff)
            try:
                await asyncio.wait_for(stop.wait(), timeout=backoff)
            except asyncio.TimeoutError:
                pass
            backoff = min(backoff * 2, 30.0)
