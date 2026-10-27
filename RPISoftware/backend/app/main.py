"""FastAPI application entrypoint for Canary backend.

Lifespan: create schema -> seed demo data -> start the MQTT consumer (if enabled)
and the hourly retention task. The MQTT task is best-effort: if the broker / aiomqtt
is unavailable the API still serves and the HTTP telemetry ingress remains usable
for testing. Three-Pi mode (app.cluster): every node serves the API and keeps a publish-only
broker connection; the MQTT subscription and retention run only while this node holds the
processing lease.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
from collections.abc import AsyncIterator, Coroutine
from typing import Any

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.admin import router as admin_router
from app.api.ai import router as ai_router
from app.api.cluster import router as cluster_router
from app.api.device_commands import router as commands_router
from app.api.firmware import router as firmware_router
from app.api.household import router as household_router
from app.api.motion import router as motion_router
from app.api.zone_normal import router as zone_normal_router
from app.api.water_impact import router as water_impact_router
from app.api.routes import router
from app import cluster
from app.care.service import CareUnavailable
from app.config import settings
from app.db import init_db
from app.i18n import LanguageMiddleware
from app.realtime.ws import manager
from app.retention import run_retention

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("canary")

CANCEL_WAIT_S = 3.0


class RedactTokens(logging.Filter):
    """Keep the JWT that WebSocket clients pass as `?token=` out of uvicorn's logs."""

    _TOKEN = re.compile(r"(token=)[^&\s\"]+")

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.args, tuple):
            record.args = tuple(self._TOKEN.sub(r"\1***", a) if isinstance(a, str) else a for a in record.args)
        return True


for _name in ("uvicorn.access", "uvicorn.error"):
    logging.getLogger(_name).addFilter(RedactTokens())


class _Workloads:
    """This process's background tasks. The processing ones (MQTT subscription, retention,
    escalation resume) run for the life of a single hub, and in three-Pi mode only while this
    node holds the processing lease."""

    def __init__(self, stop: asyncio.Event) -> None:
        self.stop = stop
        self.tasks: dict[str, asyncio.Task] = {}

    def spawn(self, name: str, coro: Coroutine[Any, Any, None]) -> None:
        self.tasks[name] = asyncio.create_task(coro, name=name)

    async def cancel(self, name: str) -> None:
        task = self.tasks.pop(name, None)
        if task is not None:
            task.cancel()
            # Bounded, and our own cancellation still propagates: a task cancelled mid-query can
            # spend a query timeout closing its session; it is stopped, waiting adds nothing.
            await asyncio.wait({task}, timeout=CANCEL_WAIT_S)

    async def mqtt(self, subscribe: bool) -> None:
        """(Re)connect to the broker, subscribed or publish-only."""
        await self.cancel("mqtt")
        if not settings.mqtt_enabled:
            return
        try:
            from app.ingestion.mqtt import run_mqtt_consumer

            self.spawn("mqtt", run_mqtt_consumer(self.stop, subscribe=subscribe))
            log.info("MQTT %s task started", "consumer" if subscribe else "publisher")
        except Exception as exc:  # noqa: BLE001 - never block API startup on MQTT
            log.warning("MQTT consumer not started: %s", exc)

    async def start_processing(self) -> None:
        from app.analytics.zone_normal import run_baselines
        from app.ingestion import espectre, hardware
        from app.notify import escalation

        hardware.reset_state()
        espectre.reset_state()  # in-memory state from an earlier turn as processing node is stale
        await escalation.resume_pending()  # escalation retries survive a restart or a failover
        self.spawn("retention", run_retention(self.stop))
        self.spawn("baselines", run_baselines(self.stop))  # per-room normal (app.analytics.zone_normal)
        await self.mqtt(subscribe=True)

    async def stop_processing(self) -> None:
        await self.mqtt(subscribe=False)  # the consumer first: it is what must not run twice
        await self.cancel("retention")
        await self.cancel("baselines")


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    cluster.check_config()
    if cluster.triple():
        await cluster.wait_for_db()  # Patroni may still be electing a primary
    async with cluster.schema_lock():  # three Pis booting together: one creates and seeds at a time
        if settings.auto_create_schema:
            await init_db()
        if settings.auto_seed:
            from app.seed import seed_if_empty

            await seed_if_empty()

    from app.notify import escalation

    stop = asyncio.Event()
    work = _Workloads(stop)
    if settings.llm_url:
        from app.ai.llm import run_probe

        work.spawn("llm_probe", run_probe(stop))
    if cluster.triple():
        manager.forwarder = cluster.forward
        await work.mqtt(subscribe=False)
        work.spawn("cluster", cluster.run(stop, work.start_processing, work.stop_processing))
    else:
        await work.start_processing()

    try:
        yield
    finally:
        stop.set()
        lease_task = work.tasks.pop("cluster", None)
        if lease_task is not None:  # let it stop processing and hand the lease on
            await asyncio.wait({lease_task}, timeout=5)
            lease_task.cancel()
        await escalation.stop()
        for name in list(work.tasks):
            await work.cancel(name)
        manager.forwarder = None


app = FastAPI(
    title="Canary API",
    version="0.1.0",
    description="Canary - Smart Building Safety & Hazard-Response Platform (backend MVP)",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_middleware(LanguageMiddleware)  # Accept-Language: ro|en for REST text (app/i18n.py)
app.include_router(router)
app.include_router(household_router)
app.include_router(commands_router)
app.include_router(admin_router)
app.include_router(firmware_router)
app.include_router(ai_router)
app.include_router(cluster_router)
app.include_router(motion_router)
app.include_router(zone_normal_router)
app.include_router(water_impact_router)


@app.exception_handler(CareUnavailable)
async def care_unavailable(_: Request, exc: CareUnavailable) -> JSONResponse:
    """Care profiles need CANARY_CARE_KEY; everything else keeps working without it."""
    return JSONResponse(status_code=503, content={"detail": str(exc)})


@app.get("/health", tags=["meta"])
async def health() -> dict:
    """`ingest`: MQTT messages waiting to be processed and the oldest one's wait (s). `cluster`: this
    node, and whether it runs the processing workloads (always in single mode)."""
    from app.ingestion.broker import ingest_stats

    return {"status": "ok", "service": "canary-backend", "version": "0.1.0", "ingest": ingest_stats(),
            "cluster": {"mode": settings.cluster_mode, "node": cluster.node_name(),
                        "processing": cluster.holds_processing()}}


@app.get("/", tags=["meta"])
async def root() -> dict:
    return {"name": "Canary", "docs": "/docs", "health": "/health"}
