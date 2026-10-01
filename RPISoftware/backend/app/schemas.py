"""Pydantic models: the MQTT telemetry wire contract (canary.telemetry.v1) and API DTOs."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.enums import (
    CheckInSource,
    CheckInStatus,
    EdgeState,
    SensorType,
    Severity,
)


# --------------------------------------------------------------------------- #
# Telemetry wire schema (ARCHITECTURE.md section 5)
# --------------------------------------------------------------------------- #
class Location(BaseModel):
    building_id: str
    floor_id: str
    unit_id: str
    zone_id: str


class Signal(BaseModel):
    rssi: float | None = None
    snr: float | None = None
    link: str = "wifi"


class Health(BaseModel):
    status: str = "ok"
    self_test: str = "pass"


class Battery(BaseModel):
    level_pct: int | None = None
    powered: str = "mains"
    low_battery: bool = False


class ReadingThresholds(BaseModel):
    """The reporting device's own grading thresholds (installer calibration), in the
    reading's units. When absent the backend defaults for the sensor type apply."""

    model_config = ConfigDict(allow_inf_nan=False)

    detection: float
    critical: float
    clear: float


class TelemetryPayload(BaseModel):
    # `schema` is the wire field name; aliased to avoid shadowing pydantic internals.
    model_config = ConfigDict(populate_by_name=True)

    schema_: str = Field(default="canary.telemetry.v1", alias="schema")
    device_id: str
    sensor_type: SensorType
    location: Location
    value: float
    units: str = ""
    edge_state: EdgeState = EdgeState.normal
    edge_inference_score: float | None = None
    signal: Signal | None = None
    health: Health | None = None
    battery: Battery | None = None
    fw_version: str = ""
    epoch: int = 0
    seq: int = 0
    device_ts: datetime | None = None
    ingest_ts: datetime | None = None
    thresholds: ReadingThresholds | None = None


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
class TokenRequest(BaseModel):
    username: str


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    user_id: str


# --------------------------------------------------------------------------- #
# API responses
# --------------------------------------------------------------------------- #
class IncidentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    building_id: str
    primary_zone_id: str | None
    hazard_type: str
    severity: str
    state: str
    opened_ts: datetime
    updated_ts: datetime
    resolved_ts: datetime | None
    last_value: float
    affected_zone_ids: list = []
    est_source_zone_id: str | None = None
    est_source_x: float | None = None
    est_source_y: float | None = None
    triangulation_confidence: float | None = None
    triangulation_method: str | None = None
    advisory: bool = False
    false_alarm_class: str | None = None
    false_alarm_reason: str | None = None
    benign_score: float | None = None


class IncidentEventOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    incident_id: str
    from_state: str
    to_state: str
    reason: str
    actor: str
    ts: datetime


class CheckInRequest(BaseModel):
    status: CheckInStatus
    unit_id: str | None = None
    source: CheckInSource = CheckInSource.cloud


class CheckInOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    incident_id: str
    user_id: str | None
    unit_id: str | None
    status: str
    source: str
    ts: datetime


class ZoneOccupancy(BaseModel):
    zone_id: str
    persons_est: float


class AccountingOut(BaseModel):
    incident_id: str
    occupancy_total: float
    accounted: int
    unaccounted: int
    needs_help: int
    zones_with_people: list[ZoneOccupancy]


class ResidentOut(BaseModel):
    """A named resident of the building (people behind the anonymous occupancy counts)."""

    user_id: str
    display_name: str
    unit_id: str | None = None
    unit_label: str | None = None
    phone: str | None = None


class RosterEntry(ResidentOut):
    """A resident enriched with their live check-in status for an active incident."""

    status: str  # safe_outside | safe_inside | needs_help | no_response | unknown
    source: str | None = None
    ts: datetime | None = None


class RosterOut(BaseModel):
    incident_id: str
    total: int
    safe: int
    needs_help: int
    awaiting: int  # not yet confirmed safe (unknown / no_response)
    entries: list[RosterEntry]


class DeviceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    building_id: str
    zone_id: str
    sensor_type: str
    status: str
    fw_version: str
    last_seen_ts: datetime | None


class BuildingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    name: str
    address: str
    timezone: str


class IngestResult(BaseModel):
    status: str  # accepted | duplicate | occupancy
    incident_id: str | None = None
    incident_state: str | None = None
    severity: Severity | None = None


class AssemblyPointOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    building_id: str
    label: str
    lat: float | None
    lon: float | None


class WaypointOut(BaseModel):
    id: str
    label: str
    kind: str
    hint: str = ""


class EvacuationRouteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    building_id: str
    floor_id: str
    from_zone_id: str | None
    to_assembly_point_id: str
    label: str
    path: list[str] = []
    waypoints: list[WaypointOut] = []


class EvacuationOut(BaseModel):
    building_id: str
    routes: list[EvacuationRouteOut]
    assembly_points: list[AssemblyPointOut]


class ZoneOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    building_id: str
    floor_id: str
    unit_id: str
    label: str
    kind: str
    pos_x: float
    pos_y: float


class TriangulationContributor(BaseModel):
    device_id: str
    zone_id: str
    value: float
    weight: float


class TriangulationOut(BaseModel):
    incident_id: str
    source_zone_id: str | None
    source_x: float | None
    source_y: float | None
    confidence: float
    method: str
    n_contributors: int
    airflow_applied: bool
    contributors: list[TriangulationContributor]


class ReadingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    device_id: str
    zone_id: str
    sensor_type: str
    value: float
    units: str
    edge_state: str
    ts: datetime


# --------------------------------------------------------------------------- #
# Hardware nodes + analysis (docs/HARDWARE.md sections 3-4)
# --------------------------------------------------------------------------- #
class IndicatorOut(BaseModel):
    key: str
    label: str
    level: str  # ok | attention | danger | unknown
    value: str
    detail: str | None = None
    trend: str | None = None  # rising | falling | stable | None


class NodeAnalysisOut(BaseModel):
    """Plain-language analysis of one node. Never carries raw measurements."""

    node_id: str
    kind: str
    name: str
    zone_id: str
    online: bool
    stale: bool
    last_seen_ts: datetime | None
    status: str  # ok | attention | danger
    headline: str
    advice: list[str]
    indicators: list[IndicatorOut]


class ZoneSummaryOut(BaseModel):
    zone_id: str
    zone_label: str
    status: str
    occupied: bool | None
    nodes: list[NodeAnalysisOut]


class BuildingSummaryOut(BaseModel):
    """Analysis-only building view (residents included): no raw measurements."""

    building_id: str
    building_name: str
    generated_ts: datetime
    status: str
    headline: str
    nodes_total: int
    nodes_online: int
    active_incidents: int
    zones: list[ZoneSummaryOut]


class NodeOut(BaseModel):
    """A physical node: latest raw status document + its analysis (dashboard)."""

    id: str
    kind: str
    mqtt_base: str
    name: str
    firmware: str
    building_id: str
    zone_id: str
    online: bool
    last_seen_ts: datetime | None
    boot_epoch: int
    status: dict | None
    analysis: NodeAnalysisOut


class NodeUpdate(BaseModel):
    zone_id: str | None = None
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)] | None = None


class HistoryPoint(BaseModel):
    ts: datetime
    values: dict[str, int | float | str | None]


class NodeHistoryOut(BaseModel):
    node_id: str
    minutes: int
    fields: list[str]
    points: list[HistoryPoint]
