"""In-process WebSocket connection manager, fanned out per building.

For a single-instance MVP this is sufficient. A multi-instance deployment would
back the fan-out with Redis pub/sub so every API node reaches every subscriber.
"""

from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any

from fastapi import WebSocket


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
        # Snapshot under lock, send outside it; drop dead sockets.
        async with self._lock:
            targets = list(self._rooms.get(building_id, set()))
        dead: list[WebSocket] = []
        for ws in targets:
            try:
                await ws.send_json(message)
            except Exception:  # noqa: BLE001 - socket closed/broken
                dead.append(ws)
        if dead:
            async with self._lock:
                for ws in dead:
                    self._rooms[building_id].discard(ws)


# Module-level singleton shared by the notifier and the WS route.
manager = ConnectionManager()
