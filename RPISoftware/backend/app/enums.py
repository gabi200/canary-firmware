"""Canonical vocabularies (ARCHITECTURE.md sections 5, 6, 7, 8).

These string tokens are the single source of truth used verbatim on the MQTT wire,
in the REST/WebSocket API, and (eventually) in the FCM payloads and the Flutter
handler. Pure stdlib so the detection / state-machine logic can be unit-tested
without any third-party dependency installed.
"""

from __future__ import annotations

from enum import Enum


class SensorType(str, Enum):
    combustible_gas = "combustible_gas"
    co = "co"
    water_leak = "water_leak"
    particulate = "particulate"  # PM2.5 from the air node (smoke / particulates)
    wifi_presence = "wifi_presence"
    radar_presence = "radar_presence"  # LD2410 presence from the air node


class HazardType(str, Enum):
    """Derived hazard tokens carried on alert/incident records (sensor_type minus occupancy types)."""

    combustible_gas = "combustible_gas"
    co = "co"
    water_leak = "water_leak"
    particulate = "particulate"


# sensor_type values that map to a hazard (presence types are occupancy, never a hazard)
HAZARD_SENSOR_TYPES: frozenset[SensorType] = frozenset(
    {SensorType.combustible_gas, SensorType.co, SensorType.water_leak, SensorType.particulate}
)

# sensor_type values routed to occupancy estimation
OCCUPANCY_SENSOR_TYPES: frozenset[SensorType] = frozenset(
    {SensorType.wifi_presence, SensorType.radar_presence}
)

# hazards for which a critical reading triggers an automatic evacuation
AUTO_EVAC_HAZARDS: frozenset[HazardType] = frozenset(
    {HazardType.combustible_gas, HazardType.co}
)


def hazard_for_sensor(sensor_type: SensorType) -> HazardType | None:
    """Map a sensor_type to its hazard_type, or None for occupancy (presence) types."""
    if sensor_type not in HAZARD_SENSOR_TYPES:
        return None
    return HazardType(sensor_type.value)


class NodeKind(str, Enum):
    """Physical ESP32 node kinds (docs/HARDWARE.md section 2)."""

    air = "air"
    water = "water"


# Logical channels each node kind owns, as Device rows `{node_id}:{channel}` (hazards first).
NODE_CHANNELS: dict[NodeKind, tuple[tuple[str, SensorType], ...]] = {
    NodeKind.air: (
        ("co", SensorType.co),
        ("gas", SensorType.combustible_gas),
        ("particulate", SensorType.particulate),
        ("presence", SensorType.radar_presence),
    ),
    NodeKind.water: (("leak", SensorType.water_leak),),
}


class EdgeState(str, Enum):
    """On-device pre-inference state. `alarm` means the node already fired its local siren."""

    normal = "normal"
    warn = "warn"
    alarm = "alarm"


class IncidentState(str, Enum):
    normal = "normal"
    detection = "detection"
    verification = "verification"
    alarm = "alarm"
    escalation = "escalation"
    evacuation = "evacuation"
    resolution = "resolution"
    false_alarm = "false_alarm"


# states in which an Incident is considered still open / active
OPEN_INCIDENT_STATES: frozenset[IncidentState] = frozenset(
    {
        IncidentState.detection,
        IncidentState.verification,
        IncidentState.alarm,
        IncidentState.escalation,
        IncidentState.evacuation,
    }
)

# active-alarm states: residents have been alerted, identity-unlock is authorized
ALARMED_STATES: frozenset[IncidentState] = frozenset(
    {IncidentState.alarm, IncidentState.escalation, IncidentState.evacuation}
)


class Severity(str, Enum):
    info = "info"
    warning = "warning"
    critical = "critical"


class CheckInStatus(str, Enum):
    safe_outside = "safe_outside"
    safe_inside = "safe_inside"
    needs_help = "needs_help"
    no_response = "no_response"


# statuses that confirm a resident is accounted for (evacuated / safe)
ACCOUNTED_STATUSES: frozenset[CheckInStatus] = frozenset({CheckInStatus.safe_outside})


class CheckInSource(str, Enum):
    cloud = "cloud"
    gateway_lan = "gateway_lan"


class Role(str, Enum):
    resident = "resident"
    hoa_manager = "hoa_manager"
    dispatcher_external = "dispatcher_external"
    system_admin = "system_admin"


class NotificationChannel(str, Enum):
    push = "push"
    web_push = "web_push"
    ws = "ws"
    external = "external"


class ExternalIntegrationKind(str, Enum):
    arc = "arc"  # contracted 24/7 alarm-receiving center / duty manager (calls 112/ISU)
    isu_webhook = "isu_webhook"  # optional machine-readable ISU feed (signed agreement only)
    gas_distributor = "gas_distributor"  # ENGIE / Distrigaz Sud
