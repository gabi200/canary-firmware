"""Pure hazard-decision engine.

No DB, no I/O, fully deterministic and unit-testable. Given a single reading plus
a small corroboration context, it returns the Incident state the system should
advance *toward* (the state machine in app.incidents.state_machine then computes
the forward path). Mirrors the guards in ARCHITECTURE.md section 7.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.detection.thresholds import Thresholds, effective_thresholds
from app.enums import (
    AUTO_EVAC_HAZARDS,
    EdgeState,
    IncidentState,
    SensorType,
    Severity,
    hazard_for_sensor,
)

# reading levels
NORMAL = "normal"
DETECTION = "detection"
CRITICAL = "critical"


def reading_level(
    sensor_type: SensorType, value: float, edge_state: EdgeState, thresholds: Thresholds | None = None
) -> str:
    """Classify a single reading as normal / detection / critical.

    `thresholds` are the device's own (installer calibration) when it sent them;
    otherwise the backend defaults for the sensor type apply.
    """
    th = effective_thresholds(sensor_type, thresholds)
    if th is None:  # presence or unknown -> not a hazard reading
        return NORMAL
    if edge_state == EdgeState.alarm or value >= th.critical:
        return CRITICAL
    if value >= th.detection or edge_state == EdgeState.warn:
        return DETECTION
    return NORMAL


def is_clearing(
    sensor_type: SensorType, value: float, edge_state: EdgeState, thresholds: Thresholds | None = None
) -> bool:
    """True when a reading is low enough to count toward clearing an open incident."""
    th = effective_thresholds(sensor_type, thresholds)
    if th is None:
        return True
    return value < th.clear and edge_state == EdgeState.normal


@dataclass(frozen=True)
class DetectionContext:
    current_state: IncidentState
    samples_over_threshold: int  # count of over-threshold samples seen for this incident (incl. current)
    distinct_devices_over: int  # distinct devices that have been over threshold
    neighbor_corroboration: bool  # another zone in the building also over threshold
    unaccounted_gt0: bool  # there are unaccounted occupants


@dataclass(frozen=True)
class Decision:
    target_state: IncidentState | None  # None => no positive hazard signal
    severity: Severity
    reason: str
    fast_path: bool  # skip the verification stage
    escalation_warranted: bool  # include the escalation stage en route to evacuation


def evaluate(
    sensor_type: SensorType,
    value: float,
    edge_state: EdgeState,
    ctx: DetectionContext,
    thresholds: Thresholds | None = None,
) -> Decision:
    """Decide the target Incident state for a hazard reading.

    Building-internal alerting is never gated on corroboration: a single node at
    its critical threshold (or an edge_state of alarm) reaches `alarm` on its own.
    Corroboration only gates the outward `escalation` hop.
    """
    hazard = hazard_for_sensor(sensor_type)
    if hazard is None:
        return Decision(None, Severity.info, "not_a_hazard", False, False)

    level = reading_level(sensor_type, value, edge_state, thresholds)
    if level == NORMAL:
        return Decision(None, Severity.info, "below_threshold", False, False)

    corroborated = (
        ctx.distinct_devices_over >= 2
        or ctx.neighbor_corroboration
        or ctx.samples_over_threshold >= 3
    )
    escalation_warranted = (level == CRITICAL and hazard in AUTO_EVAC_HAZARDS) or ctx.unaccounted_gt0

    # --- critical single-sensor fast path ---
    if level == CRITICAL:
        if hazard in AUTO_EVAC_HAZARDS:
            target = IncidentState.evacuation  # auto-evacuate critical gas/CO
        else:
            target = IncidentState.alarm
        reason = "edge_alarm" if edge_state == EdgeState.alarm else "critical_fast_path"
        return Decision(target, Severity.critical, reason, fast_path=True, escalation_warranted=escalation_warranted)

    # --- detection level (sub-critical) ---
    if corroborated:
        return Decision(
            IncidentState.alarm, Severity.warning, "corroborated", fast_path=True,
            escalation_warranted=escalation_warranted,
        )
    if ctx.samples_over_threshold <= 1:
        return Decision(
            IncidentState.detection, Severity.warning, "first_detection", fast_path=False,
            escalation_warranted=False,
        )
    return Decision(
        IncidentState.verification, Severity.warning, "awaiting_corroboration", fast_path=False,
        escalation_warranted=False,
    )
