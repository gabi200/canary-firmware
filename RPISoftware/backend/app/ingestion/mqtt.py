"""MQTT consumer. Subscribes to `settings.mqtt_subscribe` and dispatches by topic.

- `<base>/status`, `<base>/availability`: the real ESP32 firmware (app.ingestion.hardware).
- `<base>/command/result`: device command results (app.commands).
- `espectre/v1/devices/<id>/...`: ESPectre Wi-Fi motion boards (app.ingestion.espectre), first,
  so no other route ever sees them.
- `<mqtt_topic_prefix>/.../telemetry|event`: legacy canary.telemetry.v1 (simulator).
- anything else is ignored. The connected client is shared (app.ingestion.broker) so the API
  can publish device commands to the same local broker.

Three-Pi mode: every node keeps a publish-only connection (`subscribe=False`, device commands from
the API) and only the processing node subscribes, as client id `canary-processing`: the broker
disconnects an older client with the same id, so two Pis can never both consume.

aiomqtt is imported lazily so the rest of the app (and the test suite) imports
cleanly even when the MQTT client / broker is absent. The consumer reconnects with
backoff; a broker outage degrades cloud detection but never the edge-local alarm
(ARCHITECTURE.md section 8, failure mode 3).
"""

from __future__ import annotations

import asyncio
import json
import logging

from app import commands
from app.config import settings
from app.db import SessionLocal
from app.enums import EdgeState
from app.ingestion import broker, espectre
from app.ingestion.hardware import handle_hardware_message
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


async def dispatch(topic: str, raw: bytes, retain: bool = False, received_ts: float | None = None) -> None:
    """Route one message by topic; errors are logged, never raised into the loop. `received_ts`
    (epoch s) is when the MQTT client received it (default: now)."""
    try:
        if espectre.handles(topic):
            await espectre.handle_espectre_message(topic, raw, retain=retain, received_ts=received_ts)
        elif topic.endswith("/status") or topic.endswith("/availability"):
            await handle_hardware_message(topic, raw, retain=retain, received_ts=received_ts)
        elif topic.endswith("/command/result"):
            if not retain:  # results are never retained by the firmware; a retained one is stale
                await commands.handle_result(topic[: -len("/command/result")], raw, received_ts=received_ts)
        elif topic.startswith(f"{settings.mqtt_topic_prefix}/"):
            await _handle_message(topic, raw)
    except Exception:  # noqa: BLE001 - one bad message must not drop the connection
        log.exception("error handling MQTT message on %r", topic[:200])


PROCESSING_CLIENT_ID = "canary-processing"


async def run_mqtt_consumer(stop: asyncio.Event, subscribe: bool = True) -> None:
    import aiomqtt  # lazy import

    topic = settings.mqtt_subscribe
    fenced = subscribe and settings.cluster_mode == "triple"
    backoff = 1.0
    while not stop.is_set():
        try:
            async with aiomqtt.Client(
                hostname=settings.mqtt_host,
                port=settings.mqtt_port,
                username=settings.mqtt_username,
                password=settings.mqtt_password,
                identifier=PROCESSING_CLIENT_ID if fenced else None,
                # three Pis: notice a dead broker (the hub address moved to another Pi) quickly
                keepalive=15 if settings.cluster_mode == "triple" else 60,
                queue_type=broker.StampedQueue,  # stamps each message's receive time
            ) as client:
                if subscribe:
                    await client.subscribe(topic, qos=1)
                    for extra in espectre.subscriptions():
                        await client.subscribe(extra, qos=1)
                    log.info("MQTT consumer subscribed to %s", topic)
                else:
                    log.info("MQTT publish-only connection to %s", settings.mqtt_host)
                backoff = 1.0
                broker.client = client
                try:
                    async for message in client.messages:
                        await dispatch(str(message.topic), bytes(message.payload), bool(message.retain),
                                       getattr(message, "received_ts", None))
                        if stop.is_set():
                            break
                finally:
                    if broker.client is client:  # a newer connection may already have replaced it
                        broker.client = None
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - reconnect on any broker/network error
            log.warning("MQTT consumer error (%s); reconnecting in %.0fs", exc, backoff)
            try:
                await asyncio.wait_for(stop.wait(), timeout=backoff)
            except asyncio.TimeoutError:
                pass
            backoff = min(backoff * 2, 30.0)
