"""In-process WebSocket connection manager, fanned out per building.

For a single-instance MVP this is sufficient. A multi-instance deployment would
back the fan-out with Redis pub/sub so every API node reaches every subscriber.
"""

from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any

from fastapi import WebSocket

SEND_TIMEOUT_S = 2.0


class ConnectionManager:
    def __init__(self) -> None:
        self._rooms: dict[str, set[WebSocket]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def connect(self, building_id: str, ws: WebSocket) -> None:
        await ws.accept()
        async with self._lock:
            self._rooms[building_id].add(ws)

    async def disconnect(self, building_id: str, ws: WebSocket) -> None:
        async with self._lock:
            self._rooms[building_id].discard(ws)

    async def broadcast(self, building_id: str, message: dict[str, Any]) -> None:
        # Snapshot under lock, send outside it; drop dead sockets. Sends run concurrently and
        # are time-boxed: callers broadcast mid-transaction, so one stalled phone must not
        # hold the database write lock. A slow client just misses this frame.
        async with self._lock:
            targets = list(self._rooms.get(building_id, set()))

        async def send(ws: WebSocket) -> WebSocket | None:
            try:
                await asyncio.wait_for(ws.send_json(message), timeout=SEND_TIMEOUT_S)
            except asyncio.TimeoutError:
                return None
            except Exception:  # noqa: BLE001 - socket closed/broken
                return ws
            return None

        dead = [ws for ws in await asyncio.gather(*(send(ws) for ws in targets)) if ws is not None]
        if dead:
            async with self._lock:
                for ws in dead:
                    self._rooms[building_id].discard(ws)


# Module-level singleton shared by the notifier and the WS route.
manager = ConnectionManager()
