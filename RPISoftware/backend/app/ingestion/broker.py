"""The hub's connection to its local MQTT broker, shared by the consumer and the API.

* `client`: the connected aiomqtt client (set by app.ingestion.mqtt), used to publish device
  commands. Only the local broker is ever addressed (no external sending).
* `StampedQueue`: aiomqtt's incoming-message queue. aiomqtt reads the socket on the event loop
  and enqueues each message there; this stamps the receive time on it, so a processing backlog
  never turns into stale `last_seen` or a command "timeout", and exposes the backlog to /health.
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

client: Any = None  # aiomqtt.Client while connected
queue: "StampedQueue | None" = None  # the live client's incoming queue


class BrokerUnavailable(RuntimeError):
    """No connection to the MQTT broker (disabled or down)."""


async def publish(topic: str, payload: str, *, qos: int = 1, retain: bool = False) -> None:
    current = client
    if current is None:
        raise BrokerUnavailable("MQTT broker not connected")
    await current.publish(topic, payload, qos=qos, retain=retain)


class StampedQueue(asyncio.Queue):
    """asyncio.Queue that stamps `received_ts` (epoch s) on each message as it arrives."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        global queue
        queue = self

    def _put(self, item: Any) -> None:
        item.received_ts = time.time()
        super()._put(item)

    def oldest_age_s(self) -> float:
        items = self._queue  # the deque behind asyncio.Queue
        return round(time.time() - items[0].received_ts, 3) if items else 0.0


def ingest_stats() -> dict:
    """For /health: messages waiting to be processed and how long the oldest has waited."""
    current = queue
    return {
        "connected": client is not None,
        "queue": current.qsize() if current is not None else 0,
        "lag_s": current.oldest_age_s() if current is not None else 0.0,
    }
