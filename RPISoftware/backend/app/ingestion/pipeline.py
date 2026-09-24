"""Core ingestion pipeline, transport-agnostic.

Called by both the MQTT consumer and the HTTP `/telemetry` endpoint so the exact
same normalize -> dedupe -> persist -> route logic runs regardless of how the
message arrived (matching the LoRa-rehydrated and WiFi paths converging on one
schema, ARCHITECTURE.md section 5).
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.detection.thresholds import Thresholds
from app.enums import OCCUPANCY_SENSOR_TYPES
from app.incidents.service import IncidentService
from app.models import Device, SensorReading
from app.occupancy.service import OccupancyService
from app.schemas import IngestResult, TelemetryPayload


async def _is_duplicate(session: AsyncSession, device_id: str, epoch: int, seq: int) -> bool:
    # Idempotency key is (device_id, epoch, seq). Because epoch is part of the key,
    # a node reboot (epoch++ , seq restarts at 0) is NOT mistaken for a duplicate.
    existing = await session.scalar(
        select(SensorReading.id).where(
            SensorReading.device_id == device_id,
            SensorReading.epoch == epoch,
            SensorReading.seq == seq,
        )
    )
    return existing is not None


async def ingest_telemetry(session: AsyncSession, payload: TelemetryPayload) -> IngestResult:
    if await _is_duplicate(session, payload.device_id, payload.epoch, payload.seq):
        return IngestResult(status="duplicate")

    now = datetime.now(timezone.utc)
    loc = payload.location
    sig = payload.signal
    reading = SensorReading(
        device_id=payload.device_id,
        building_id=loc.building_id,
        floor_id=loc.floor_id,
        unit_id=loc.unit_id,
        zone_id=loc.zone_id,
        sensor_type=payload.sensor_type.value,
        value=payload.value,
        units=payload.units,
        edge_state=payload.edge_state.value,
        edge_inference_score=payload.edge_inference_score,
        rssi=sig.rssi if sig else None,
        snr=sig.snr if sig else None,
        link=sig.link if sig else "wifi",
        epoch=payload.epoch,
        seq=payload.seq,
        device_ts=payload.device_ts,
        ts=now,
    )
    session.add(reading)

    # best-effort device liveness update
    device = await session.get(Device, payload.device_id)
    if device is not None:
        device.last_seen_ts = now

    # route by sensor type
    if payload.sensor_type in OCCUPANCY_SENSOR_TYPES:
        await OccupancyService(session).record_presence(
            building_id=loc.building_id,
            zone_id=loc.zone_id,
            persons_est=payload.value,
            confidence=payload.edge_inference_score or 0.6,
            ts=device_ts_or(now, payload.device_ts),
        )
        await session.commit()
        return IngestResult(status="occupancy")

    incident = await IncidentService(session).handle_hazard_reading(
        building_id=loc.building_id,
        zone_id=loc.zone_id,
        device_id=payload.device_id,
        sensor_type=payload.sensor_type,
        value=payload.value,
        edge_state=payload.edge_state,
        device_ts=payload.device_ts,
        thresholds=_device_thresholds(payload),
    )
    await session.commit()

    if incident is None:
        return IngestResult(status="accepted")
    return IngestResult(
        status="accepted",
        incident_id=incident.id,
        incident_state=incident.state,
        severity=incident.severity,
    )


def device_ts_or(default: datetime, device_ts: datetime | None) -> datetime:
    return device_ts or default


def _device_thresholds(payload: TelemetryPayload) -> Thresholds | None:
    t = payload.thresholds
    if t is None:
        return None
    return Thresholds(detection=t.detection, critical=t.critical, clear=t.clear, units=payload.units)
