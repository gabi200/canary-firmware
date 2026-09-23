"""SQLAlchemy ORM models (ARCHITECTURE.md section 6).

Enum-typed fields are stored as their canonical string tokens (app.enums) so the
DB, the wire schema, and the API all agree. Time-series entities (SensorReading,
DeviceHealth, OccupancyEstimate) become TimescaleDB hypertables on Postgres.
Physical ESP32 nodes (Node) and their raw status history (NodeStatus) follow
docs/HARDWARE.md.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.types import TypeDecorator

from app.db import Base


def _uuid() -> str:
    return uuid.uuid4().hex


def _now() -> datetime:
    return datetime.now(timezone.utc)


class UTCDateTime(TypeDecorator):
    """Timezone-aware UTC on every dialect. SQLite drops tzinfo on round-trip, which
    made the API emit zone-less timestamps that clients read as local time."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect) -> datetime | None:
        if value is not None and value.tzinfo is not None:
            value = value.astimezone(timezone.utc)
        return value

    def process_result_value(self, value: datetime | None, dialect) -> datetime | None:
        if value is not None and value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value


def _ts_col(**kw) -> Mapped[datetime]:
    return mapped_column(UTCDateTime, default=_now, **kw)


# --------------------------------------------------------------------------- #
# Spatial hierarchy: Building -> Floor -> Unit -> Zone -> Device
# --------------------------------------------------------------------------- #
class Building(Base):
    __tablename__ = "buildings"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    name: Mapped[str] = mapped_column(String, default="")
    address: Mapped[str] = mapped_column(String, default="")
    timezone: Mapped[str] = mapped_column(String, default="Europe/Bucharest")


class Floor(Base):
    __tablename__ = "floors"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    level: Mapped[int] = mapped_column(Integer, default=0)
    label: Mapped[str] = mapped_column(String, default="")


class Unit(Base):
    __tablename__ = "units"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    floor_id: Mapped[str] = mapped_column(ForeignKey("floors.id"), index=True)
    label: Mapped[str] = mapped_column(String, default="")
    kind: Mapped[str] = mapped_column(String, default="residential")  # residential | common


class Zone(Base):
    __tablename__ = "zones"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    floor_id: Mapped[str] = mapped_column(ForeignKey("floors.id"), index=True)
    unit_id: Mapped[str] = mapped_column(ForeignKey("units.id"), index=True)
    label: Mapped[str] = mapped_column(String, default="")
    kind: Mapped[str] = mapped_column(String, default="")  # kitchen | boiler | bedroom | hallway ...
    # 2D position within the building (metres, arbitrary origin) for spatial triangulation.
    pos_x: Mapped[float] = mapped_column(Float, default=0.0)
    pos_y: Mapped[float] = mapped_column(Float, default=0.0)


class Device(Base):
    __tablename__ = "devices"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    floor_id: Mapped[str] = mapped_column(ForeignKey("floors.id"))
    unit_id: Mapped[str] = mapped_column(ForeignKey("units.id"))
    zone_id: Mapped[str] = mapped_column(ForeignKey("zones.id"), index=True)
    sensor_type: Mapped[str] = mapped_column(String, index=True)
    fw_version: Mapped[str] = mapped_column(String, default="")
    status: Mapped[str] = mapped_column(String, default="ok")
    installed_ts: Mapped[datetime] = _ts_col()
    last_seen_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class Node(Base):
    """A physical ESP32 (air or water), keyed by its MQTT base topic and auto-registered
    on its first status document. Owns logical Device rows `{id}:{channel}`."""

    __tablename__ = "nodes"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    kind: Mapped[str] = mapped_column(String)  # app.enums.NodeKind token
    mqtt_base: Mapped[str] = mapped_column(String, unique=True)
    name: Mapped[str] = mapped_column(String, default="")
    firmware: Mapped[str] = mapped_column(String, default="")
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    zone_id: Mapped[str] = mapped_column(ForeignKey("zones.id"), index=True)
    online: Mapped[bool] = mapped_column(Boolean, default=True)
    last_seen_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    last_uptime_ms: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    boot_epoch: Mapped[int] = mapped_column(Integer, default=1)
    last_status: Mapped[dict | None] = mapped_column(JSON, nullable=True)  # latest raw document
    created_ts: Mapped[datetime] = _ts_col()


# --------------------------------------------------------------------------- #
# People & access
# --------------------------------------------------------------------------- #
class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    username: Mapped[str] = mapped_column(String, unique=True, index=True)
    display_name: Mapped[str] = mapped_column(String, default="")
    role: Mapped[str] = mapped_column(String, default="resident")  # app.enums.Role token
    phone: Mapped[str] = mapped_column(String, default="")
    email: Mapped[str] = mapped_column(String, default="")
    created_ts: Mapped[datetime] = _ts_col()


class ResidentUnit(Base):
    __tablename__ = "resident_units"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    unit_id: Mapped[str] = mapped_column(ForeignKey("units.id"), index=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)


# --------------------------------------------------------------------------- #
# Incidents (the safety-critical spine)
# --------------------------------------------------------------------------- #
class Incident(Base):
    __tablename__ = "incidents"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    primary_zone_id: Mapped[str | None] = mapped_column(String, nullable=True)
    hazard_type: Mapped[str] = mapped_column(String, index=True)
    severity: Mapped[str] = mapped_column(String, default="warning")
    state: Mapped[str] = mapped_column(String, default="detection", index=True)
    opened_ts: Mapped[datetime] = _ts_col()
    updated_ts: Mapped[datetime] = _ts_col()
    resolved_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    # corroboration / clearing bookkeeping (MVP-local fields)
    last_value: Mapped[float] = mapped_column(Float, default=0.0)
    samples_over_threshold: Mapped[int] = mapped_column(Integer, default=0)
    distinct_device_ids: Mapped[list] = mapped_column(JSON, default=list)
    affected_zone_ids: Mapped[list] = mapped_column(JSON, default=list)
    clear_count: Mapped[int] = mapped_column(Integer, default=0)
    # AI hazard-source triangulation estimate (ARCHITECTURE.md section B.1)
    est_source_zone_id: Mapped[str | None] = mapped_column(String, nullable=True)
    est_source_x: Mapped[float | None] = mapped_column(Float, nullable=True)
    est_source_y: Mapped[float | None] = mapped_column(Float, nullable=True)
    triangulation_confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    triangulation_method: Mapped[str | None] = mapped_column(String, nullable=True)
    triangulation_detail: Mapped[dict] = mapped_column(JSON, default=dict)
    # False-alarm reduction assessment (ARCHITECTURE.md section B.3)
    false_alarm_class: Mapped[str | None] = mapped_column(String, nullable=True)
    false_alarm_reason: Mapped[str | None] = mapped_column(String, nullable=True)
    benign_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    advisory: Mapped[bool] = mapped_column(Boolean, default=False)  # micro-leak trend / non-alarming


class IncidentEvent(Base):
    __tablename__ = "incident_events"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    incident_id: Mapped[str] = mapped_column(ForeignKey("incidents.id"), index=True)
    from_state: Mapped[str] = mapped_column(String)
    to_state: Mapped[str] = mapped_column(String)
    reason: Mapped[str] = mapped_column(String, default="")
    actor: Mapped[str] = mapped_column(String, default="system")
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    ts: Mapped[datetime] = _ts_col()


class CheckIn(Base):
    __tablename__ = "check_ins"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    incident_id: Mapped[str] = mapped_column(ForeignKey("incidents.id"), index=True)
    user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    unit_id: Mapped[str | None] = mapped_column(ForeignKey("units.id"), nullable=True)
    status: Mapped[str] = mapped_column(String)  # app.enums.CheckInStatus
    source: Mapped[str] = mapped_column(String, default="cloud")  # cloud | gateway_lan
    ts: Mapped[datetime] = _ts_col()


class Notification(Base):
    __tablename__ = "notifications"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    incident_id: Mapped[str] = mapped_column(ForeignKey("incidents.id"), index=True)
    channel: Mapped[str] = mapped_column(String)  # app.enums.NotificationChannel
    recipient_user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    recipient_integration_id: Mapped[str | None] = mapped_column(
        ForeignKey("external_integrations.id"), nullable=True
    )
    severity: Mapped[str] = mapped_column(String, default="warning")
    state: Mapped[str] = mapped_column(String, default="")
    title: Mapped[str] = mapped_column(String, default="")
    body: Mapped[str] = mapped_column(String, default="")
    delivered: Mapped[bool] = mapped_column(Boolean, default=False)
    sent_ts: Mapped[datetime] = _ts_col()


class AuditLogEntry(Base):
    """Append-only safety audit log. (Tamper-evident hash-chaining is a later phase;
    for the MVP this is an ordinary append-only table.)"""

    __tablename__ = "audit_log"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    incident_id: Mapped[str | None] = mapped_column(ForeignKey("incidents.id"), nullable=True, index=True)
    actor: Mapped[str] = mapped_column(String, default="system")
    action: Mapped[str] = mapped_column(String)
    target: Mapped[str] = mapped_column(String, default="")
    identity_unlock: Mapped[bool] = mapped_column(Boolean, default=False)
    detail: Mapped[dict] = mapped_column(JSON, default=dict)
    ts: Mapped[datetime] = _ts_col()


# --------------------------------------------------------------------------- #
# Evacuation geometry & external integrations
# --------------------------------------------------------------------------- #
class AssemblyPoint(Base):
    __tablename__ = "assembly_points"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    label: Mapped[str] = mapped_column(String, default="")
    lat: Mapped[float | None] = mapped_column(Float, nullable=True)
    lon: Mapped[float | None] = mapped_column(Float, nullable=True)


class EvacuationRoute(Base):
    __tablename__ = "evacuation_routes"
    id: Mapped[str] = mapped_column(String, primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    floor_id: Mapped[str] = mapped_column(ForeignKey("floors.id"))
    from_zone_id: Mapped[str | None] = mapped_column(String, nullable=True)
    to_assembly_point_id: Mapped[str] = mapped_column(ForeignKey("assembly_points.id"))
    label: Mapped[str] = mapped_column(String, default="")
    path: Mapped[list] = mapped_column(JSON, default=list)  # ordered list of waypoints/zone ids


class ExternalIntegration(Base):
    __tablename__ = "external_integrations"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    kind: Mapped[str] = mapped_column(String)  # app.enums.ExternalIntegrationKind
    endpoint: Mapped[str] = mapped_column(String, default="")
    sla_answer_secs: Mapped[int | None] = mapped_column(Integer, nullable=True)
    sla_call_to_112_secs: Mapped[int | None] = mapped_column(Integer, nullable=True)
    isu_agreement_signed: Mapped[bool] = mapped_column(Boolean, default=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True)


# --------------------------------------------------------------------------- #
# Time-series (TimescaleDB hypertables on Postgres)
# --------------------------------------------------------------------------- #
class SensorReading(Base):
    __tablename__ = "sensor_readings"
    __table_args__ = (UniqueConstraint("device_id", "epoch", "seq", name="uq_reading_device_epoch_seq"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_id: Mapped[str] = mapped_column(String, index=True)
    building_id: Mapped[str] = mapped_column(String, index=True)
    floor_id: Mapped[str] = mapped_column(String)
    unit_id: Mapped[str] = mapped_column(String)
    zone_id: Mapped[str] = mapped_column(String, index=True)
    sensor_type: Mapped[str] = mapped_column(String, index=True)
    value: Mapped[float] = mapped_column(Float)
    units: Mapped[str] = mapped_column(String, default="")
    edge_state: Mapped[str] = mapped_column(String, default="normal")
    edge_inference_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    rssi: Mapped[float | None] = mapped_column(Float, nullable=True)
    snr: Mapped[float | None] = mapped_column(Float, nullable=True)
    link: Mapped[str] = mapped_column(String, default="wifi")
    epoch: Mapped[int] = mapped_column(Integer, default=0)
    # 64-bit: hardware nodes use uptime_ms as seq, which outgrows a 32-bit int in ~25 days.
    seq: Mapped[int] = mapped_column(BigInteger, default=0)
    device_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    ts: Mapped[datetime] = _ts_col(index=True)  # ingest_ts


class DeviceHealth(Base):
    __tablename__ = "device_health"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_id: Mapped[str] = mapped_column(String, index=True)
    status: Mapped[str] = mapped_column(String, default="ok")
    self_test: Mapped[str] = mapped_column(String, default="pass")
    battery_level_pct: Mapped[int | None] = mapped_column(Integer, nullable=True)
    powered: Mapped[str] = mapped_column(String, default="mains")
    low_battery: Mapped[bool] = mapped_column(Boolean, default=False)
    ts: Mapped[datetime] = _ts_col(index=True)


class OccupancyEstimate(Base):
    __tablename__ = "occupancy_estimates"
    # serves the latest-estimate-per-zone lookup (polled by dashboards)
    __table_args__ = (Index("ix_occupancy_building_zone_ts", "building_id", "zone_id", "ts"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    zone_id: Mapped[str] = mapped_column(String, index=True)
    building_id: Mapped[str] = mapped_column(String, index=True)
    persons_est: Mapped[float] = mapped_column(Float, default=0.0)
    confidence: Mapped[float] = mapped_column(Float, default=0.5)
    ts: Mapped[datetime] = _ts_col(index=True)


class NodeStatus(Base):
    """Raw status snapshot: one row per accepted status document, payload verbatim."""

    __tablename__ = "node_status"
    __table_args__ = (Index("ix_node_status_node_ts", "node_id", "ts"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[str] = mapped_column(String)  # indexed by ix_node_status_node_ts
    ts: Mapped[datetime] = _ts_col(index=True)  # hub receipt time (devices have no wall clock)
    uptime_ms: Mapped[int] = mapped_column(BigInteger)
    payload: Mapped[dict] = mapped_column(JSON)
