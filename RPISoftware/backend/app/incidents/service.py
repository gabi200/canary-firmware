"""Incident orchestration: turns readings + manual actions into state transitions.

Owns the Incident lifecycle, appends an IncidentEvent per transition (append-only
audit of the spine), and calls the NotificationService on each new state. The
*decision* of which state to target is delegated to the pure detection engine; the
*legality* of moving there to the pure state machine. This service only persists
and side-effects.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.analytics.false_alarm import MICRO_LEAK_TREND, ReadingSample, classify
from app.analytics.service import AnalyticsService, _epoch
from app.analytics.signature.rules import SignatureAssessment
from app.detection.engine import NORMAL, DetectionContext, evaluate, is_clearing, reading_level
from app.detection.thresholds import Thresholds, effective_thresholds
from app.enums import (
    ALARMED_STATES,
    AUTO_EVAC_HAZARDS,
    OPEN_INCIDENT_STATES,
    EdgeState,
    HazardType,
    IncidentState,
    SensorType,
    hazard_for_sensor,
)
from app.incidents.state_machine import can_transition, closing_state, forward_chain
from app.models import Incident, IncidentEvent, SensorReading
from app.notify.service import NotificationService
from app.occupancy.service import OccupancyService

log = logging.getLogger("canary.incidents")

# Triangulation runs once an incident is corroborated (verification) and onward.
_TRIANGULATION_STATES = {IncidentState.verification} | ALARMED_STATES

# Window (s) of a device's recent readings the false-alarm classifier inspects.
_FALSE_ALARM_WINDOW_S = 1800


def _now() -> datetime:
    return datetime.now(timezone.utc)


class IncidentService:
    def __init__(self, session: AsyncSession, notifier: NotificationService | None = None) -> None:
        self.session = session
        self.notifier = notifier or NotificationService(session)
        self.occupancy = OccupancyService(session)

    # --- automatic path (driven by telemetry) -------------------------------
    async def handle_hazard_reading(
        self,
        *,
        building_id: str,
        zone_id: str,
        device_id: str,
        sensor_type: SensorType,
        value: float,
        edge_state: EdgeState,
        device_ts: datetime | None = None,
        thresholds: Thresholds | None = None,
    ) -> Incident | None:
        """`thresholds` are the reporting device's own (installer calibration); when
        absent the backend defaults for `sensor_type` apply."""
        hazard = hazard_for_sensor(sensor_type)
        if hazard is None:
            return None

        th = effective_thresholds(sensor_type, thresholds)
        incident = await self._open_incident(building_id, hazard.value)
        level = reading_level(sensor_type, value, edge_state, th)

        # Clearing path: count consecutive low readings, close after the hold window.
        # Only a device that reported this hazard can clear it: another node's normal
        # heartbeat must never "all clear" an incident whose source went silent.
        if is_clearing(sensor_type, value, edge_state, th):
            if incident is not None and device_id in (incident.distinct_device_ids or []):
                incident.clear_count += 1
                from app.config import settings

                if incident.clear_count >= settings.clear_hold_samples:
                    await self._close(incident)
            return incident

        # Sub-threshold (above clear, below detection): not an alarm. Look for a slow
        # micro-leak trend; never create a phantom over-threshold incident here.
        if level == NORMAL:
            if incident is None:
                await self._maybe_micro_leak(building_id, zone_id, device_id, sensor_type, th)
            return incident

        # Over-threshold: open if needed, update corroboration bookkeeping.
        if incident is None:
            incident = Incident(
                building_id=building_id,
                hazard_type=hazard.value,
                primary_zone_id=zone_id,
                state=IncidentState.normal.value,
                severity="warning",
                distinct_device_ids=[],
                affected_zone_ids=[],
            )
            self.session.add(incident)
            await self.session.flush()  # materialize incident.id for events

        incident.clear_count = 0
        incident.last_value = value
        incident.samples_over_threshold += 1
        incident.advisory = False  # a real over-threshold reading is no longer advisory-only
        devices = set(incident.distinct_device_ids or [])
        devices.add(device_id)
        incident.distinct_device_ids = sorted(devices)
        zones = set(incident.affected_zone_ids or [])
        zones.add(zone_id)
        incident.affected_zone_ids = sorted(zones)

        unaccounted_gt0 = False
        if IncidentState(incident.state) in ALARMED_STATES:
            acc = await self.occupancy.accounting(incident.id, building_id)
            unaccounted_gt0 = acc.unaccounted > 0

        multi_sensor = len(devices) >= 2 or len(zones) >= 2
        ctx = DetectionContext(
            current_state=IncidentState(incident.state),
            samples_over_threshold=incident.samples_over_threshold,
            distinct_devices_over=len(devices),
            neighbor_corroboration=len(zones) >= 2,
            unaccounted_gt0=unaccounted_gt0,
        )
        decision = evaluate(sensor_type, value, edge_state, ctx, th)
        if decision.target_state is None:
            return incident

        # False-alarm reduction: classify the signal shape. May HOLD a corroborated,
        # non-critical escalation in verification. Critical / edge alarms are never held.
        assessment = await self._assess_false_alarm(
            building_id, device_id, sensor_type, edge_state, multi_sensor, th
        )
        incident.false_alarm_class = assessment.classification
        incident.false_alarm_reason = assessment.reason
        incident.benign_score = assessment.benign_score

        # Hazard signature (air nodes): a fire signature cancels every hold, for any hazard;
        # a confident benign one may hold only a corroborated PARTICULATE escalation from a
        # single sensor in a single zone. Gas / CO and real cross-sensor corroboration are
        # never held by it. Critical readings and node alarms never reach these branches
        # (their reason is never "corroborated").
        signature = await self._classify_signature(incident, device_id)

        target = decision.target_state
        reason = decision.reason
        fast_path = decision.fast_path
        corroborated = decision.reason == "corroborated"
        if signature is not None and signature.overrides_hold:
            pass
        elif corroborated and assessment.suppress_escalation:
            target = IncidentState.verification
            reason = f"held_{assessment.classification}"
            fast_path = False
        elif (
            corroborated
            and hazard == HazardType.particulate
            and not multi_sensor
            and signature is not None
            and signature.allows_hold
        ):
            target = IncidentState.verification
            reason = f"held_signature_{signature.label}"
            fast_path = False

        chain = forward_chain(
            IncidentState(incident.state),
            target,
            fast_path=fast_path,
            escalation_warranted=decision.escalation_warranted,
        )
        incident.severity = decision.severity.value
        for to_state in chain:
            await self._transition(
                incident,
                to_state,
                reason=reason,
                actor="system",
                payload={"device_id": device_id, "value": value, "sensor_type": sensor_type.value},
            )

        # AI hazard-source triangulation (verification onward; gas/CO only). Best-effort:
        # never let analytics break the safety path.
        if IncidentState(incident.state) in _TRIANGULATION_STATES and hazard in AUTO_EVAC_HAZARDS:
            try:
                await AnalyticsService(self.session).triangulate_incident(incident)
            except Exception:  # noqa: BLE001
                pass

        incident.updated_ts = _now()
        return incident

    # --- false-alarm reduction helpers --------------------------------------
    async def _device_window(
        self, building_id: str, device_id: str, sensor_type: SensorType
    ) -> list[ReadingSample]:
        since = _now() - timedelta(seconds=_FALSE_ALARM_WINDOW_S)
        rows = (
            await self.session.scalars(
                select(SensorReading)
                .where(
                    SensorReading.building_id == building_id,
                    SensorReading.device_id == device_id,
                    SensorReading.sensor_type == sensor_type.value,
                    SensorReading.ts >= since,
                )
                .order_by(SensorReading.ts.asc())
            )
        ).all()
        return [ReadingSample(ts=_epoch(r.ts), value=r.value) for r in rows]

    async def _assess_false_alarm(
        self,
        building_id: str,
        device_id: str,
        sensor_type: SensorType,
        edge_state: EdgeState,
        multi_sensor: bool,
        thresholds: Thresholds | None = None,
    ):
        th = effective_thresholds(sensor_type, thresholds)
        window = await self._device_window(building_id, device_id, sensor_type)
        return classify(
            window,
            detection=th.detection,
            critical=th.critical,
            clear=th.clear,
            multi_sensor=multi_sensor,
            edge_alarm=(edge_state == EdgeState.alarm),
        )

    async def _classify_signature(self, incident: Incident, device_id: str) -> SignatureAssessment | None:
        """Signature of the device's node; None for devices without one. Best-effort: a
        failure here must never change the safety path."""
        node_id, sep, _ = device_id.partition(":")
        if not sep:
            return None
        # Flush the incident's own pending state first (errors here are not the classifier's and
        # propagate), then isolate the classifier's reads and assessment INSERT in a savepoint.
        await self.session.flush()
        try:
            # SAVEPOINT needs an open transaction; the flush above guarantees one (pysqlite/aiosqlite).
            async with self.session.begin_nested():
                return await AnalyticsService(self.session).classify_signature(node_id, incident.id)
        except Exception:  # noqa: BLE001
            log.exception("signature classification failed for %s", device_id)
            return None

    async def _maybe_micro_leak(
        self,
        building_id: str,
        zone_id: str,
        device_id: str,
        sensor_type: SensorType,
        thresholds: Thresholds | None = None,
    ) -> Incident | None:
        """Open a low-severity advisory incident when a slow sub-threshold rise is
        detected (managers only — not a resident alarm)."""
        th = effective_thresholds(sensor_type, thresholds)
        window = await self._device_window(building_id, device_id, sensor_type)
        assessment = classify(
            window, detection=th.detection, critical=th.critical, clear=th.clear,
            multi_sensor=False, edge_alarm=False,
        )
        if assessment.classification != MICRO_LEAK_TREND:
            return None

        hazard = hazard_for_sensor(sensor_type)
        assert hazard is not None
        incident = Incident(
            building_id=building_id,
            hazard_type=hazard.value,
            primary_zone_id=zone_id,
            state=IncidentState.normal.value,
            severity="info",
            advisory=True,
            distinct_device_ids=[device_id],
            affected_zone_ids=[zone_id],
            false_alarm_class=assessment.classification,
            false_alarm_reason=assessment.reason,
            benign_score=assessment.benign_score,
        )
        self.session.add(incident)
        await self.session.flush()
        await self._transition(incident, IncidentState.detection, reason="micro_leak_trend", actor="analytics")
        return incident

    # --- manual actions (managers / dispatchers) ----------------------------
    async def dismiss(self, incident_id: str, actor: str, reason: str = "manual_dismiss") -> Incident | None:
        incident = await self.session.get(Incident, incident_id)
        if incident is None or IncidentState(incident.state) not in OPEN_INCIDENT_STATES:
            return incident
        # Once residents have been alarmed (alarm/escalation/evacuation) the incident can
        # only be *resolved*, never retroactively re-labelled a false alarm. Surface this
        # as a clear conflict instead of letting the state-machine guard raise a bare 500.
        if not can_transition(IncidentState(incident.state), IncidentState.false_alarm):
            raise ValueError(
                "cannot dismiss as a false alarm once residents are alarmed — use Resolve instead"
            )
        await self._transition(incident, IncidentState.false_alarm, reason=reason, actor=actor)
        incident.resolved_ts = _now()
        return incident

    async def order_evacuation(self, incident_id: str, actor: str) -> Incident | None:
        incident = await self.session.get(Incident, incident_id)
        if incident is None or IncidentState(incident.state) not in OPEN_INCIDENT_STATES:
            return incident
        chain = forward_chain(
            IncidentState(incident.state),
            IncidentState.evacuation,
            fast_path=True,
            escalation_warranted=False,
        )
        for to_state in chain:
            await self._transition(incident, to_state, reason="manual_order", actor=actor)
        return incident

    async def resolve(self, incident_id: str, actor: str) -> Incident | None:
        incident = await self.session.get(Incident, incident_id)
        if incident is None or IncidentState(incident.state) not in OPEN_INCIDENT_STATES:
            return incident
        await self._transition(incident, IncidentState.resolution, reason="manual_resolve", actor=actor)
        incident.resolved_ts = _now()
        return incident

    # --- internals ----------------------------------------------------------
    async def _open_incident(self, building_id: str, hazard_type: str) -> Incident | None:
        open_states = [s.value for s in OPEN_INCIDENT_STATES]
        return await self.session.scalar(
            select(Incident)
            .where(
                Incident.building_id == building_id,
                Incident.hazard_type == hazard_type,
                Incident.state.in_(open_states),
            )
            .order_by(Incident.opened_ts.desc())
            .limit(1)
        )

    async def _close(self, incident: Incident) -> None:
        target = closing_state(IncidentState(incident.state))
        await self._transition(incident, target, reason="readings_cleared", actor="system")
        incident.resolved_ts = _now()

    async def _transition(
        self,
        incident: Incident,
        to_state: IncidentState,
        *,
        reason: str,
        actor: str,
        payload: dict | None = None,
    ) -> None:
        from_state = IncidentState(incident.state)
        if not can_transition(from_state, to_state):
            # Forward-only safety guard: refuse illegal transitions rather than corrupt state.
            raise ValueError(f"illegal transition {from_state.value} -> {to_state.value}")
        self.session.add(
            IncidentEvent(
                incident_id=incident.id,
                from_state=from_state.value,
                to_state=to_state.value,
                reason=reason,
                actor=actor,
                payload=payload or {},
                ts=_now(),
            )
        )
        incident.state = to_state.value
        incident.updated_ts = _now()
        await self.notifier.on_state(incident, to_state)
