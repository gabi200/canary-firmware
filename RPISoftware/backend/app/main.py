"""FastAPI application entrypoint for Canary backend.

Lifespan: create schema -> seed demo data -> start the MQTT consumer (if enabled)
and the hourly retention task. The MQTT task is best-effort: if the broker / aiomqtt
is unavailable the API still serves and the HTTP telemetry ingress remains usable
for testing.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import re
from collections.abc import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.admin import router as admin_router
from app.api.device_commands import router as commands_router
from app.api.household import router as household_router
from app.api.routes import router
from app.care.service import CareUnavailable
from app.config import settings
from app.db import init_db
from app.i18n import LanguageMiddleware
from app.retention import run_retention

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("canary")


class RedactTokens(logging.Filter):
    """Keep the JWT that WebSocket clients pass as `?token=` out of uvicorn's logs."""

    _TOKEN = re.compile(r"(token=)[^&\s\"]+")

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.args, tuple):
            record.args = tuple(self._TOKEN.sub(r"\1***", a) if isinstance(a, str) else a for a in record.args)
        return True


for _name in ("uvicorn.access", "uvicorn.error"):
    logging.getLogger(_name).addFilter(RedactTokens())


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if settings.auto_create_schema:
        await init_db()
    if settings.auto_seed:
        from app.seed import seed_if_empty

        await seed_if_empty()

    from app.notify import escalation

    await escalation.resume_pending()  # escalation retries survive a restart

    stop = asyncio.Event()
    retention_task = asyncio.create_task(run_retention(stop))
    mqtt_task: asyncio.Task | None = None
    if settings.mqtt_enabled:
        try:
            from app.ingestion.mqtt import run_mqtt_consumer

            mqtt_task = asyncio.create_task(run_mqtt_consumer(stop))
            log.info("MQTT consumer task started")
        except Exception as exc:  # noqa: BLE001 - never block API startup on MQTT
            log.warning("MQTT consumer not started: %s", exc)

    try:
        yield
    finally:
        stop.set()
        await escalation.stop()
        for task in (mqtt_task, retention_task):
            if task is not None:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task


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


@app.exception_handler(CareUnavailable)
async def care_unavailable(_: Request, exc: CareUnavailable) -> JSONResponse:
    """Care profiles need CANARY_CARE_KEY; everything else keeps working without it."""
    return JSONResponse(status_code=503, content={"detail": str(exc)})


@app.get("/health", tags=["meta"])
async def health() -> dict:
    """`ingest`: MQTT messages waiting to be processed and the oldest one's wait (s)."""
    from app.ingestion.broker import ingest_stats

    return {"status": "ok", "service": "canary-backend", "version": "0.1.0", "ingest": ingest_stats()}


@app.get("/", tags=["meta"])
async def root() -> dict:
    return {"name": "Canary", "docs": "/docs", "health": "/health"}
