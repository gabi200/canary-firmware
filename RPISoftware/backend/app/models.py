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
        if value is not None:
            # naive is UTC, as on read (asyncpg would take a naive value as the hub's local time)
            value = value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)
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


class NodeInbox(Base):
    """A node that registered itself (first status document) and nobody has placed in a room
    yet: the technician's "new sensors" list. A new table so `nodes` stays untouched; the row
    goes when the node is moved to a zone."""

    __tablename__ = "node_inbox"
    node_id: Mapped[str] = mapped_column(ForeignKey("nodes.id"), primary_key=True)
    ts: Mapped[datetime] = _ts_col()


class NodeOtaTarget(Base):
    """Where and how the hub pushes firmware to a node (app.firmware): the device's HTTP address,
    pinned by staff (never taken from MQTT unchecked), and its API token as a Fernet token under
    CANARY_CARE_KEY. A new table so `nodes` stays untouched."""

    __tablename__ = "node_ota_targets"
    node_id: Mapped[str] = mapped_column(ForeignKey("nodes.id"), primary_key=True)
    address: Mapped[str] = mapped_column(String)  # ip or ip:port
    token_enc: Mapped[str] = mapped_column(String)
    updated_ts: Mapped[datetime] = _ts_col()


class NodeFirmwareSeen(Base):
    """A firmware version a node reported, from the first status document that carried it."""

    __tablename__ = "node_firmware_seen"
    __table_args__ = (Index("ix_node_firmware_seen_node_ts", "node_id", "ts"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    node_id: Mapped[str] = mapped_column(String)
    firmware: Mapped[str] = mapped_column(String)
    ts: Mapped[datetime] = _ts_col()


class FirmwareUpdate(Base):
    """One firmware push from the dashboard to a node's `/api/ota`. status: queued | uploading |
    flashed (the device took the image and reboots) | confirmed (it came back) | failed; a job
    stuck before that reads as `timeout` (computed on read)."""

    __tablename__ = "firmware_updates"
    __table_args__ = (Index("ix_firmware_updates_node_created", "node_id", "created_ts"),)
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    node_id: Mapped[str] = mapped_column(String)
    building_id: Mapped[str] = mapped_column(String, index=True)
    filename: Mapped[str] = mapped_column(String)
    size: Mapped[int] = mapped_column(Integer)
    sha256: Mapped[str] = mapped_column(String)
    firmware_before: Mapped[str] = mapped_column(String, default="")
    firmware_after: Mapped[str | None] = mapped_column(String, nullable=True)  # reported after the reboot
    status: Mapped[str] = mapped_column(String, default="queued")
    detail: Mapped[str | None] = mapped_column(String, nullable=True)  # device error token / network error
    requested_by_user_id: Mapped[str] = mapped_column(String)
    created_ts: Mapped[datetime] = _ts_col()
    flashed_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    finished_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


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


class ResidentLocation(Base):
    """Where a resident said they are during an incident (app.enums.Whereabouts); latest answer wins."""

    __tablename__ = "resident_locations"
    incident_id: Mapped[str] = mapped_column(ForeignKey("incidents.id"), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    location: Mapped[str] = mapped_column(String)
    ts: Mapped[datetime] = _ts_col()


class UserStatus(Base):
    """Account switch (a new table: `users` stays untouched). No row = active."""

    __tablename__ = "user_status"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    updated_ts: Mapped[datetime] = _ts_col()


class StaffBuilding(Base):
    """Which buildings an hoa_manager runs. A manager with no row runs every building (legacy
    single-building hubs)."""

    __tablename__ = "staff_buildings"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), primary_key=True)


class DeviceCommand(Base):
    """A command published to a node (`<base>/buzzer/set`, `<base>/valve/set`) and its result from
    `<base>/command/result`. status: sent | accepted | rejected (timeout is computed on read)."""

    __tablename__ = "device_commands"
    __table_args__ = (Index("ix_device_commands_node_sent", "node_id", "sent_ts"),)
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    node_id: Mapped[str] = mapped_column(String)
    building_id: Mapped[str] = mapped_column(String, index=True)
    command: Mapped[str] = mapped_column(String)  # TEST | SILENCE | OPEN | CLOSE
    status: Mapped[str] = mapped_column(String, default="sent")
    detail: Mapped[str | None] = mapped_column(String, nullable=True)  # firmware `state` or `error`
    requested_by_user_id: Mapped[str] = mapped_column(String)
    sent_ts: Mapped[datetime] = _ts_col()
    result_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class HouseholdInvite(Base):
    """A single-use link inviting someone to join a unit. Only the SHA-256 of the code is stored."""

    __tablename__ = "household_invites"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    code_hash: Mapped[str] = mapped_column(String, unique=True)  # hex sha256 of the code
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    unit_id: Mapped[str] = mapped_column(ForeignKey("units.id"), index=True)
    inviter_user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    care_profile_id: Mapped[str | None] = mapped_column(String, nullable=True)  # a non-self profile to hand over
    created_ts: Mapped[datetime] = _ts_col()
    expires_ts: Mapped[datetime] = mapped_column(UTCDateTime)
    used_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    used_by_user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id"), nullable=True)
    revoked_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class HouseholdInviteAttempt(Base):
    """One invite preview / accept call, for the per-user hourly ceiling (rows older than an hour go)."""

    __tablename__ = "household_invite_attempts"
    __table_args__ = (Index("ix_household_invite_attempts_user_ts", "user_id", "ts"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(String)
    ts: Mapped[datetime] = _ts_col()


class UserPref(Base):
    """Per-user preferences (a new table so existing `users` rows stay untouched)."""

    __tablename__ = "user_prefs"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    language: Mapped[str] = mapped_column(String, default="ro")  # ro | en


class EscalationDelivery(Base):
    """One attempt to deliver an escalation webhook event. `incident_id` has no foreign key on
    purpose: the event is built inside the transition's transaction and must be recordable
    from the delivery task's own session."""

    __tablename__ = "escalation_deliveries"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    event_id: Mapped[str] = mapped_column(String, index=True)
    incident_id: Mapped[str] = mapped_column(String, index=True)
    state: Mapped[str] = mapped_column(String)  # incident state the event reports
    attempt: Mapped[int] = mapped_column(Integer)  # 1..4
    status_code: Mapped[int | None] = mapped_column(Integer, nullable=True)  # HTTP status, None on error
    error: Mapped[str | None] = mapped_column(String, nullable=True)  # timeout | connection error ...
    delivered: Mapped[bool] = mapped_column(Boolean, default=False)
    ts: Mapped[datetime] = _ts_col()


class EscalationOutbox(Base):
    """An escalation event until it is settled, so retries survive a hub restart (resumed for
    30 min). `body` is the original JSON (Fernet-sealed when CANARY_CARE_KEY is set), cleared
    once delivered / failed / expired."""

    __tablename__ = "escalation_outbox"
    event_id: Mapped[str] = mapped_column(String, primary_key=True)
    incident_id: Mapped[str] = mapped_column(String, index=True)
    state: Mapped[str] = mapped_column(String)
    body: Mapped[str] = mapped_column(String, default="")
    sealed: Mapped[bool] = mapped_column(Boolean, default=False)
    attempts: Mapped[int] = mapped_column(Integer, default=0)  # made so far
    status: Mapped[str] = mapped_column(String, default="pending", index=True)  # pending|delivered|failed|expired
    next_attempt_ts: Mapped[datetime] = mapped_column(UTCDateTime)
    created_ts: Mapped[datetime] = _ts_col()


class TriangulationSnapshot(Base):
    """Every distinct triangulation estimate computed for an incident (time series, pruned)."""

    __tablename__ = "triangulation_snapshots"
    __table_args__ = (Index("ix_triangulation_snapshots_incident_ts", "incident_id", "ts"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    incident_id: Mapped[str] = mapped_column(ForeignKey("incidents.id"))
    ts: Mapped[datetime] = _ts_col(index=True)
    source_zone_id: Mapped[str | None] = mapped_column(String, nullable=True)
    source_x: Mapped[float | None] = mapped_column(Float, nullable=True)
    source_y: Mapped[float | None] = mapped_column(Float, nullable=True)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    method: Mapped[str] = mapped_column(String, default="")
    n_contributors: Mapped[int] = mapped_column(Integer, default=0)
    airflow_applied: Mapped[bool] = mapped_column(Boolean, default=False)
    contributors: Mapped[list] = mapped_column(JSON, default=list)


class CareProfile(Base):
    """A person who may not evacuate alone (GDPR art. 9 health data, explicit consent).
    `*_enc` columns hold Fernet tokens (app.care); `person_user_id` is the owner for their
    own (is_self) profile and null for a household member without the app. A new table,
    so `create_all` adds it to existing databases."""

    __tablename__ = "care_profiles"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    building_id: Mapped[str] = mapped_column(ForeignKey("buildings.id"), index=True)
    unit_id: Mapped[str] = mapped_column(ForeignKey("units.id"))
    owner_user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    person_user_id: Mapped[str | None] = mapped_column(ForeignKey("users.id"), nullable=True, unique=True)
    display_name_enc: Mapped[str] = mapped_column(String)
    needs_enc: Mapped[str] = mapped_column(String)
    note_enc: Mapped[str | None] = mapped_column(String, nullable=True)
    consent_ts: Mapped[datetime] = _ts_col()
    created_ts: Mapped[datetime] = _ts_col()
    updated_ts: Mapped[datetime] = _ts_col()


class CareCheckIn(Base):
    """A resident reporting the status of one of their care profiles during an incident."""

    __tablename__ = "care_check_ins"
    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    incident_id: Mapped[str] = mapped_column(ForeignKey("incidents.id"), index=True)
    care_profile_id: Mapped[str] = mapped_column(ForeignKey("care_profiles.id"), index=True)
    by_user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    status: Mapped[str] = mapped_column(String)  # app.enums.CheckInStatus (safe_* | needs_help)
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
    __table_args__ = (
        UniqueConstraint("device_id", "epoch", "seq", name="uq_reading_device_epoch_seq"),
        # trend + false-alarm windows: one device, recent rows (also created on start, app.db)
        Index("ix_sensor_readings_device_ts", "device_id", "ts"),
    )
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


class SignatureAssessmentRow(Base):
    """Hazard signature classifier output, one row per incident evaluation of an air node
    (docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md). The shadow_*
    fields are the model's opinion only; no decision reads them."""

    __tablename__ = "signature_assessments"
    __table_args__ = (Index("ix_signature_incident_id", "incident_id", "id"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    incident_id: Mapped[str] = mapped_column(String)  # indexed by ix_signature_incident_id
    node_id: Mapped[str] = mapped_column(String)
    label: Mapped[str] = mapped_column(String)
    confidence: Mapped[float] = mapped_column(Float)
    scores: Mapped[dict] = mapped_column(JSON, default=dict)
    evidence: Mapped[list] = mapped_column(JSON, default=list)
    shadow_label: Mapped[str | None] = mapped_column(String, nullable=True)
    shadow_confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    model_version: Mapped[str | None] = mapped_column(String, nullable=True)
    ts: Mapped[datetime] = _ts_col(index=True)


class MotionSensor(Base):
    """An ESPectre Wi-Fi motion board (app.ingestion.espectre) and its retained health / sensing
    state. Motion is evidence of movement only: never a person count or an empty room."""

    __tablename__ = "motion_sensors"
    device_id: Mapped[str] = mapped_column(String, primary_key=True)
    zone_id: Mapped[str | None] = mapped_column(String, nullable=True)  # None: not in CANARY_ESPECTRE_ZONES
    building_id: Mapped[str | None] = mapped_column(String, nullable=True, index=True)
    online: Mapped[bool | None] = mapped_column(Boolean, nullable=True)  # None: no health message yet
    ready: Mapped[bool | None] = mapped_column(Boolean, nullable=True)  # None: no sensing message yet
    calibrating: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    threshold: Mapped[float | None] = mapped_column(Float, nullable=True)
    firmware: Mapped[str] = mapped_column(String, default="")
    last_seen_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)  # any message
    last_motion_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)  # last `motion` state


class MotionObservation(Base):
    """One stored ESPectre motion event: every state change, and an unchanged state at most every
    CANARY_ESPECTRE_STORE_INTERVAL_S. `source_ms` is the board's monotonic clock (ms since boot),
    `ts` the hub's receive time. `ready` is the board's readiness when it was received."""

    __tablename__ = "motion_observations"
    __table_args__ = (Index("ix_motion_observations_device_ts", "device_id", "ts"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    device_id: Mapped[str] = mapped_column(String)
    zone_id: Mapped[str] = mapped_column(String, index=True)
    building_id: Mapped[str] = mapped_column(String)
    score: Mapped[float] = mapped_column(Float)
    state: Mapped[str] = mapped_column(String)  # idle | motion
    source_ms: Mapped[int] = mapped_column(BigInteger)
    ready: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    ts: Mapped[datetime] = _ts_col(index=True)


class ZoneBaseline(Base):
    """A room's frozen "normal" for one metric (app.analytics.baseline): median / MAD over a past
    reference window without incidents. hour -1: all hours, else a building-local hour bucket.
    median None: still learning (n samples so far). source: live (from readings) | seed (labelled
    synthetic demo data, tools/baseline_seed.py)."""

    __tablename__ = "zone_baselines"
    __table_args__ = (UniqueConstraint("zone_id", "sensor_type", "hour", name="uq_zone_baseline"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    building_id: Mapped[str] = mapped_column(String, index=True)
    zone_id: Mapped[str] = mapped_column(String)
    sensor_type: Mapped[str] = mapped_column(String)
    hour: Mapped[int] = mapped_column(Integer, default=-1)
    median: Mapped[float | None] = mapped_column(Float, nullable=True)
    mad: Mapped[float | None] = mapped_column(Float, nullable=True)
    n: Mapped[int] = mapped_column(Integer, default=0)
    ref_start: Mapped[datetime] = mapped_column(UTCDateTime)
    ref_end: Mapped[datetime] = mapped_column(UTCDateTime)
    source: Mapped[str] = mapped_column(String, default="live")
    computed_ts: Mapped[datetime] = _ts_col()


# --------------------------------------------------------------------------- #
# Three-Pi cluster (app.cluster); unused in single mode
# --------------------------------------------------------------------------- #
class ClusterNode(Base):
    """One row per Pi, heartbeated every couple of seconds. Times are the DB server's clock."""

    __tablename__ = "cluster_nodes"
    name: Mapped[str] = mapped_column(String, primary_key=True)  # processing | web | ai
    last_seen_ts: Mapped[datetime] = mapped_column(UTCDateTime)
    up_since_ts: Mapped[datetime] = mapped_column(UTCDateTime)  # this process's first heartbeat
    info: Mapped[dict] = mapped_column(JSON, default=dict)  # {"vip": bool, "accelerator": {...} | None}


class ClusterLease(Base):
    """A singleton role (today only `processing`): held by `holder` until `expires_ts` (DB clock)."""

    __tablename__ = "cluster_leases"
    role: Mapped[str] = mapped_column(String, primary_key=True)
    holder: Mapped[str | None] = mapped_column(String, nullable=True)
    expires_ts: Mapped[datetime] = mapped_column(UTCDateTime)
    acquired_ts: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)


class HubSetting(Base):
    """Hub-wide key/value settings (currently only `mode`: demo or real)."""

    __tablename__ = "hub_settings"
    key: Mapped[str] = mapped_column(String, primary_key=True)
    value: Mapped[str] = mapped_column(String)
    updated_ts: Mapped[datetime] = _ts_col()
    updated_by: Mapped[str | None] = mapped_column(String, nullable=True)
