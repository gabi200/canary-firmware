"""Pydantic models: the MQTT telemetry wire contract (canary.telemetry.v1) and API DTOs."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StringConstraints, field_validator, model_validator

from app.enums import (
    CareNeed,
    CheckInSource,
    CheckInStatus,
    EdgeState,
    SensorType,
    Severity,
    Whereabouts,
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


# --------------------------------------------------------------------------- #
# Self-service account (/me)
# --------------------------------------------------------------------------- #
_PHONE_SEPARATORS = re.compile(r"[\s.\-()/]")
_E164 = re.compile(r"\+[1-9]\d{7,14}")
_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s.]+")
PHONE_HINT = "phone must be a Romanian number (0722 123 456) or international E.164 (+40722123456); \"\" clears it"


def normalize_phone(raw: str) -> str:
    """E.164 from a Romanian (0722 123 456, 0040 722 123 456) or international (+40722123456)
    number; "" stays "" (clears). ValueError for anything else."""
    phone = _PHONE_SEPARATORS.sub("", raw.strip())
    if not phone:
        return ""
    if re.fullmatch(r"0[1-9]\d{8}", phone):  # national: 0 + 9 digits
        phone = "+40" + phone[1:]
    elif phone.startswith("00"):  # international prefix
        phone = "+" + phone[2:]
    if not _E164.fullmatch(phone) or (phone.startswith("+40") and len(phone) != 12):
        raise ValueError(PHONE_HINT)
    return phone


class MeUnitOut(BaseModel):
    unit_id: str
    unit_label: str
    building_id: str
    floor_label: str | None
    kind: str  # residential | common


class MeOut(BaseModel):
    user_id: str
    username: str
    display_name: str
    role: str
    phone: str  # E.164, or "" when unset
    email: str
    language: str  # ro | en (notifications); "ro" until chosen
    units: list[MeUnitOut]  # from resident_units; empty for staff


class MeUpdate(BaseModel):
    """Any of the editable fields; username, role and anything else are refused (422)."""

    model_config = ConfigDict(extra="forbid")
    display_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)] | None = None
    phone: str | None = None
    email: Annotated[str, StringConstraints(strip_whitespace=True, max_length=254)] | None = None
    language: Literal["ro", "en"] | None = None

    @field_validator("phone")
    @classmethod
    def _phone(cls, value: str | None) -> str | None:
        return None if value is None else normalize_phone(value)

    @field_validator("email")
    @classmethod
    def _email(cls, value: str | None) -> str | None:
        if value and not _EMAIL.fullmatch(value):
            raise ValueError("email must look like name@example.com; \"\" clears it")
        return value

    @model_validator(mode="after")
    def _no_nulls(self) -> "MeUpdate":
        for name in self.model_fields_set:
            if getattr(self, name) is None:
                raise ValueError(f"{name} cannot be null; use \"\" to clear phone or email")
        return self


# --------------------------------------------------------------------------- #
# Admin API (docs/HARDWARE.md section 4)
# --------------------------------------------------------------------------- #
USERNAME = r"^[a-z0-9._-]{3,32}$"
DisplayName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)]


def _email_or_blank(value: str | None) -> str | None:
    if value and not _EMAIL.fullmatch(value):
        raise ValueError("email must look like name@example.com; \"\" clears it")
    return value


class AdminUnitRef(BaseModel):
    unit_id: str
    unit_label: str


class AdminUserOut(BaseModel):
    user_id: str
    username: str
    display_name: str
    role: str
    phone: str
    email: str
    active: bool
    units: list[AdminUnitRef]


class AdminUserIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: Annotated[str, StringConstraints(pattern=USERNAME)]
    display_name: DisplayName
    role: Literal["resident", "hoa_manager", "dispatcher_external", "technician", "system_admin"]
    phone: str = ""
    email: Annotated[str, StringConstraints(strip_whitespace=True, max_length=254)] = ""
    unit_ids: list[str] = Field(default_factory=list, max_length=20)

    _phone = field_validator("phone")(classmethod(lambda cls, v: normalize_phone(v)))
    _email = field_validator("email")(classmethod(lambda cls, v: _email_or_blank(v)))


class AdminUserUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    display_name: DisplayName | None = None
    role: Literal["resident", "hoa_manager", "dispatcher_external", "technician", "system_admin"] | None = None
    phone: str | None = None
    email: Annotated[str, StringConstraints(strip_whitespace=True, max_length=254)] | None = None
    unit_ids: list[str] | None = Field(default=None, max_length=20)
    active: StrictBool | None = None

    _phone = field_validator("phone")(classmethod(lambda cls, v: None if v is None else normalize_phone(v)))
    _email = field_validator("email")(classmethod(lambda cls, v: _email_or_blank(v)))

    @model_validator(mode="after")
    def _no_nulls(self) -> "AdminUserUpdate":
        for name in self.model_fields_set:
            if getattr(self, name) is None:
                raise ValueError(f"{name} cannot be null")
        return self


class FloorOut(BaseModel):
    floor_id: str
    label: str
    level: int


class FloorIn(BaseModel):
    label: Label
    level: int = Field(ge=-10, le=200)


class AdminUnitOut(BaseModel):
    unit_id: str
    label: str
    floor_id: str
    floor_label: str | None
    kind: str  # residential | common
    residents: int


class UnitIn(BaseModel):
    label: Label
    floor_id: str
    kind: Literal["residential", "common"]


class UnitUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    label: Label | None = None
    kind: Literal["residential", "common"] | None = None


class ZoneNodeOut(BaseModel):
    node_id: str
    name: str
    kind: str
    online: bool
    status: str  # analysis status: ok | attention | danger


class AdminZoneOut(BaseModel):
    zone_id: str
    label: str
    kind: str
    unit_id: str
    unit_label: str | None
    floor_id: str
    floor_label: str | None
    pos_x: float
    pos_y: float
    nodes: list[ZoneNodeOut]


ZoneKindName = Literal["kitchen", "living_room", "bedroom", "bathroom", "hallway", "stairwell", "boiler", "other"]


class ZoneIn(BaseModel):
    label: Label
    kind: ZoneKindName
    unit_id: str
    pos_x: float = Field(default=0.0, ge=-1000, le=1000)
    pos_y: float = Field(default=0.0, ge=-1000, le=1000)


class ZoneUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    label: Label | None = None
    kind: ZoneKindName | None = None
    unit_id: str | None = None
    pos_x: float | None = Field(default=None, ge=-1000, le=1000)
    pos_y: float | None = Field(default=None, ge=-1000, le=1000)


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    user_id: str


# --------------------------------------------------------------------------- #
# API responses
# --------------------------------------------------------------------------- #
class SignatureOut(BaseModel):
    """Latest hazard signature assessment for an incident. shadow_* is the shadow
    model's opinion only; it never affects the incident."""

    model_config = ConfigDict(from_attributes=True)
    label: str
    confidence: float
    evidence: list[str] = []
    shadow_label: str | None = None
    shadow_confidence: float | None = None
    model_version: str | None = None
    ts: datetime


class FusionInputOut(BaseModel):
    name: str
    age_seconds: float | None
    status: Literal["fresh", "stale", "missing"]


class EvidenceItemOut(BaseModel):
    source: Literal["sensor_trust", "motion", "zone_normal"]
    zone_id: str | None
    subject: str  # device id, zone id or metric
    status: str
    role: Literal["supporting", "contradicting", "context", "missing"]
    strength: Literal["weak", "normal"]
    reason: str


class FusionExplanationOut(BaseModel):
    incident_id: str
    score: float
    score_kind: Literal["benign_likelihood"]
    classification: str
    assessed_ts: datetime
    fresh_witnesses: int
    supporting_evidence: list[str]
    contradicting_evidence: list[str]
    missing_inputs: list[str]
    active_overrides: list[str]
    inputs: list[FusionInputOut]
    evidence_items: list[EvidenceItemOut] = []  # labels only: never part of score or classification


class SensorTrustChannelOut(BaseModel):
    device_id: str
    sensor_type: str
    state: Literal["ok", "suspect", "lost"]
    reason: str
    sample_count: int
    input_age_seconds: float | None


class SensorTrustOut(BaseModel):
    node_id: str
    state: Literal["ok", "suspect", "lost"]
    reason: str
    channels: list[SensorTrustChannelOut]


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
    signature: SignatureOut | None = None


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


class LocationIn(BaseModel):
    location: Whereabouts


class LocationOut(BaseModel):
    incident_id: str
    location: str
    ts: datetime


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
    priority_awaiting: int = 0  # care-profile people not confirmed safe (open incidents only)


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
    location: str | None = None  # home | building | outside, as the resident answered


# --------------------------------------------------------------------------- #
# Care profiles (special needs; GDPR art. 9 health data, docs/HARDWARE.md section 4)
# --------------------------------------------------------------------------- #
class CareProfileIn(BaseModel):
    unit_id: str
    display_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)]
    is_self: bool
    needs: list[CareNeed] = Field(default_factory=list, max_length=16)
    note: Annotated[str, StringConstraints(strip_whitespace=True, max_length=280)] | None = None
    consent: StrictBool

    @field_validator("consent")
    @classmethod
    def _explicit_consent(cls, value: bool) -> bool:
        if value is not True:
            raise ValueError("explicit consent (true) is required to store care needs")
        return value

    @model_validator(mode="after")
    def _needs_or_note(self) -> "CareProfileIn":
        self.needs = list(dict.fromkeys(self.needs))
        self.note = self.note or None
        if not self.needs and not self.note:
            raise ValueError("give at least one need or a note")
        return self


# --------------------------------------------------------------------------- #
# Household invites (docs/HARDWARE.md section 4)
# --------------------------------------------------------------------------- #
class HouseholdInviteIn(BaseModel):
    unit_id: str
    care_profile_id: str | None = None  # a non-self care profile of the caller in that unit


class HouseholdInviteCreated(BaseModel):
    id: str
    code: str  # returned only here; the hub keeps its SHA-256
    url: str
    app_url: str
    unit_id: str
    unit_label: str
    care_profile_id: str | None
    expires_ts: datetime


class HouseholdInviteOut(BaseModel):
    id: str
    unit_id: str
    unit_label: str
    care_profile_id: str | None
    care_profile_name: str | None
    created_ts: datetime
    expires_ts: datetime


class InvitePreviewOut(BaseModel):
    building_name: str
    unit_label: str
    floor_label: str | None
    inviter_name: str
    has_care_profile: bool
    care_profile_name: str | None
    expires_ts: datetime


class InviteAcceptIn(BaseModel):
    take_over_care_profile: StrictBool = False
    consent: StrictBool = False

    @model_validator(mode="after")
    def _consent_for_take_over(self) -> "InviteAcceptIn":
        if self.take_over_care_profile and self.consent is not True:
            raise ValueError("taking over a care profile needs explicit consent (true)")
        return self


class InviteAcceptOut(BaseModel):
    unit_id: str
    unit_label: str
    building_id: str
    care_profile_id: str | None  # the care profile now yours, if one was handed over


class HouseholdMemberOut(BaseModel):
    user_id: str
    display_name: str
    is_me: bool
    since: datetime | None  # when they joined by invite; null for members registered otherwise


class HouseholdOut(BaseModel):
    unit_id: str
    unit_label: str
    members: list[HouseholdMemberOut]


class CareProfileOut(BaseModel):
    id: str
    unit_id: str
    unit_label: str | None
    display_name: str
    is_self: bool
    needs: list[str]
    note: str | None
    consent_ts: datetime
    updated_ts: datetime


class CareCheckInRequest(BaseModel):
    care_profile_id: str
    status: Literal["safe_outside", "safe_inside", "needs_help"]


class PriorityPersonOut(BaseModel):
    care_profile_id: str
    display_name: str
    unit_id: str
    unit_label: str | None
    floor_label: str | None
    needs: list[str]
    note: str | None
    status: str  # needs_help | no_response | unknown | safe_inside | safe_outside
    status_ts: datetime | None
    contact_name: str | None  # the profile owner
    contact_phone: str | None


class RosterOut(BaseModel):
    incident_id: str
    total: int
    safe: int
    needs_help: int
    awaiting: int  # not yet confirmed safe (unknown / no_response)
    entries: list[RosterEntry]
    priority: list[PriorityPersonOut] = []  # care profiles, only while the incident is open
    priority_awaiting: int = 0  # priority people not confirmed safe


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
    unit_label: str | None = None
    floor_label: str | None = None
    pos_x: float
    pos_y: float


class TriangulationContributor(BaseModel):
    device_id: str
    zone_id: str
    value: float
    weight: float


class TriangulationSnapshotOut(BaseModel):
    ts: datetime
    source_zone_id: str | None
    source_x: float | None
    source_y: float | None
    confidence: float
    method: str
    n_contributors: int
    airflow_applied: bool
    contributors: list[TriangulationContributor]


class TriangulationHistoryOut(BaseModel):
    incident_id: str
    snapshots: list[TriangulationSnapshotOut]  # oldest first, <= 500


class TimelineGapOut(BaseModel):
    start: datetime
    end: datetime
    seconds: float


class TimelineDeviceOut(BaseModel):
    device_id: str
    zone_id: str
    sensor_type: str
    order: int | None  # rank of first over-threshold arrival; None: never crossed in the window
    first_seen_ts: datetime
    first_over_ts: datetime | None
    first_over_value: float | None
    peak: float
    sample_count: int
    out_of_order: int  # readings received after a later seq of the same boot
    gaps: list[TimelineGapOut]


class TimelineEstimateOut(BaseModel):
    ts: datetime
    source_zone_id: str | None
    confidence: float
    method: str
    n_contributors: int


class TimelineMotionOut(BaseModel):
    ts: datetime
    zone_id: str
    device_id: str
    state: str
    score: float


class EvidenceTimelineOut(BaseModel):
    """Stored rows only (GET /incidents/{id}/evidence-timeline); estimates are listed apart from
    the observed readings, never merged into them."""

    incident_id: str
    window_start: datetime
    window_end: datetime
    truncated: bool
    devices: list[TimelineDeviceOut]
    estimates: list[TimelineEstimateOut]
    motion: list[TimelineMotionOut]


class EscalationOut(BaseModel):
    """One escalation webhook event, summarized over its delivery attempts."""

    event_id: str
    state: str  # incident state it reported: escalation | evacuation | resolution
    attempts: int
    last_status: int | None  # HTTP status of the last attempt; None on timeout / network error
    last_error: str | None
    delivered: bool
    ts: datetime  # last attempt


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


class IncidentBriefOut(BaseModel):
    """A few sentences for responders, written from database facts only (app.ai.brief)."""

    incident_id: str
    text: str
    source: Literal["llm", "template"]
    model: str | None  # the LLM that wrote it; None for the template
    node: str  # the hub node that wrote it ("hub" in single mode)
    generated_ts: datetime


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


# --------------------------------------------------------------------------- #
# Device commands (docs/HARDWARE.md section 4)
# --------------------------------------------------------------------------- #
class CommandIn(BaseModel):
    command: Literal["TEST", "SILENCE", "OPEN", "CLOSE"]


class CommandSentOut(BaseModel):
    command_id: str
    node_id: str
    command: str
    status: str  # "sent"
    sent_ts: datetime


class CommandOut(BaseModel):
    command_id: str
    command: str
    status: str  # sent | accepted | rejected | timeout
    detail: str | None  # firmware result: `state` when accepted, `error` when rejected
    requested_by_name: str | None
    sent_ts: datetime
    result_ts: datetime | None


class SummaryNodeOut(NodeAnalysisOut):
    last_command: CommandOut | None = None


class ZoneSummaryOut(BaseModel):
    zone_id: str
    zone_label: str
    unit_id: str | None = None  # the zone's flat / common unit
    unit_label: str | None = None
    status: str
    occupied: bool | None
    nodes: list[SummaryNodeOut]


class BuildingSummaryOut(BaseModel):
    """Analysis-only building view (residents included): no raw measurements."""

    building_id: str
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
    last_command: CommandOut | None = None
    is_new: bool = False  # registered itself, not placed in a room yet (technician inbox)


class NodeUpdate(BaseModel):
    zone_id: str | None = None
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)] | None = None


# --------------------------------------------------------------------------- #
# Firmware (app.firmware): versions and pushes to a node's /api/ota
# --------------------------------------------------------------------------- #
_ADDRESS = re.compile(r"^(\d{1,3}(\.\d{1,3}){3})(:\d{1,5})?$")


class OtaTargetIn(BaseModel):
    """The device's HTTP address (IPv4, optional :port) and its API token (portal field, 12-64 chars;
    omitted: keep the stored one, e.g. to follow a new DHCP address)."""

    address: Annotated[str, StringConstraints(strip_whitespace=True, max_length=21)]
    token: Annotated[str, StringConstraints(min_length=12, max_length=64, pattern=r"^[\x20-\x7e]+$")] | None = None

    @field_validator("address")
    @classmethod
    def _ipv4(cls, v: str) -> str:
        m = _ADDRESS.match(v)
        if not m or any(int(p) > 255 for p in m.group(1).split(".")) or (m.group(3) and not 0 < int(m.group(3)[1:]) < 65536):
            raise ValueError("an IPv4 address, optionally with :port")
        return v


class FirmwareUpdateOut(BaseModel):
    update_id: str
    node_id: str
    filename: str
    size: int
    sha256: str
    firmware_before: str
    firmware_after: str | None
    status: str  # queued | uploading | flashed | confirmed | failed | timeout
    detail: str | None
    requested_by_name: str | None
    created_ts: datetime
    finished_ts: datetime | None


class FirmwareSeenOut(BaseModel):
    firmware: str
    ts: datetime  # first status document that reported it


class NodeFirmwareOut(BaseModel):
    """A node's firmware: version now, where the hub would push to, and why it cannot (if so)."""

    node_id: str
    name: str
    kind: str
    zone_id: str
    online: bool
    firmware: str
    reported_ip: str | None  # `wifi.ip` of the latest status document (firmware >= 1.1.0)
    address: str | None  # pinned by staff; pushes go here only
    token_set: bool
    blocked: str | None  # offline | no_target | busy | ota_active; None = ready
    last_update: FirmwareUpdateOut | None


class NodeFirmwareDetailOut(NodeFirmwareOut):
    history: list[FirmwareSeenOut]  # newest first
    updates: list[FirmwareUpdateOut]  # newest first


class HistoryPoint(BaseModel):
    ts: datetime
    values: dict[str, int | float | str | None]


class NodeHistoryOut(BaseModel):
    node_id: str
    minutes: int
    fields: list[str]
    points: list[HistoryPoint]


class MotionSensorOut(BaseModel):
    """An ESPectre Wi-Fi motion board. `state`: motion | no_recent_motion | calibrating | unavailable."""

    model_config = ConfigDict(from_attributes=True)
    device_id: str
    zone_id: str | None
    state: str
    reason: str
    firmware: str
    last_seen_ts: datetime | None
    last_motion_ts: datetime | None


class ZoneMotionOut(BaseModel):
    """Motion evidence for one zone. Movement only: never a person count, and `no_recent_motion`
    is not an empty room. `no_presence_sensor`: no board is configured for the zone."""

    model_config = ConfigDict(from_attributes=True)
    zone_id: str
    label: str
    state: str
    last_motion_ts: datetime | None
    last_motion_age_s: float | None
    sensors: list[MotionSensorOut]


class BuildingMotionOut(BaseModel):
    building_id: str
    zones: list[ZoneMotionOut]
    unmapped: list[MotionSensorOut]  # boards seen on the broker with no zone in CANARY_ESPECTRE_ZONES


class MetricNormalOut(BaseModel):
    """A room's latest reading against its own frozen normal (app.analytics.baseline). `score` is a
    robust deviation (MAD units), a heuristic and not a probability. Evidence only: the absolute
    thresholds still decide every alarm. source `seed`: labelled synthetic demo data."""

    model_config = ConfigDict(from_attributes=True)
    sensor_type: str
    status: str  # usual | unusual_high | unusual_low | learning | no_recent_data
    score: float | None
    value: float | None
    median: float | None
    mad: float | None
    n: int
    hour: int | None  # -1: all hours; 0-23: the building-local hour bucket compared with
    source: str | None
    ref_start: datetime | None
    ref_end: datetime | None


class ZoneNormalOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    zone_id: str
    label: str
    metrics: list[MetricNormalOut]


class BuildingNormalOut(BaseModel):
    building_id: str
    zones: list[ZoneNormalOut]


class WaterImpactUnitOut(BaseModel):
    unit_id: str
    label: str
    reason: str  # below | riser
    hops: int | None  # floors under the leak (below); None for riser
    via_unit_id: str
    riser: str | None = None


class WaterImpactOut(BaseModel):
    """Units a water leak may reach, from the configured plumbing topology. Potentially affected
    only: no volume estimate and no valve action. topology: configured | not_configured | invalid."""

    incident_id: str
    applicable: bool  # false: not a water-leak incident
    topology: str
    leaking_units: list[WaterImpactUnitOut]  # reason "leak", hops 0
    affected: list[WaterImpactUnitOut]


class ScenarioIn(BaseModel):
    unavailable: list[Annotated[str, StringConstraints(max_length=64)]] = Field(default_factory=list, max_length=64)


class ScenarioNodeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    label: str
    kind: str
    people: int


class ScenarioEdgeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    a: str
    b: str
    length_m: float
    capacity_ppm: float


class ScenarioRoomOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    room_id: str
    people: int
    exit_id: str | None
    path: list[str]
    edges: list[str]
    length_m: float | None


class ScenarioLoadOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    edge_id: str
    people: int
    capacity_ppm: float
    minutes_to_clear: float


class ScenarioOut(BaseModel):
    """An evacuation what-if on a simulated graph (app.scenario.evacuation). Not linked to the
    building's evacuation routes or any incident: `label` says "scenario — not a safety prediction"."""

    graph_id: str
    graph_label: str
    label: str
    simulated: bool = True
    nodes: list[ScenarioNodeOut]
    edges: list[ScenarioEdgeOut]
    unavailable: list[str]
    unknown_ids: list[str]
    rooms: list[ScenarioRoomOut]
    loads: list[ScenarioLoadOut]
    stranded_people: int
