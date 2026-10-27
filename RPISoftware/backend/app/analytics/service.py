"""Analytics service: runs triangulation and the hazard signature classifier from live DB state.

The pure estimates (triangulation, the signature shadow model) go through app.ai.offload: the AI
node computes them in three-Pi mode, this process otherwise. The signature rules, which may hold
or release an escalation, always run here.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from statistics import median

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai import offload
from app.analytics.anomalies import AnomalySample, assess_channel, is_stale
from app.analytics.evidence import evidence_items
from app.analytics.false_alarm import ReadingSample, classify
from app.analytics.nodes import device_ids
from app.analytics.signature.features import extract_features, parse_snapshot
from app.analytics.signature.rules import FIRE_LABELS, SignatureAssessment, assess
from app.analytics.triangulation import SensorPoint, TriangulationResult
from app.detection.thresholds import thresholds_for
from app.enums import NodeKind, SensorType
from app.models import Device, Incident, Node, NodeStatus, SensorReading, SignatureAssessmentRow, TriangulationSnapshot, Zone

log = logging.getLogger("canary.signature")

# Seconds of an air node's status documents the signature classifier looks at.
SIGNATURE_WINDOW_S = 600
TRUST_HISTORY_MAX = 5000
FUSION_HISTORY_MAX = 2000
FUSION_WINDOW_S = 1800
FUSION_FRESH_S = 90


def _epoch(dt: datetime) -> float:
    """UTC epoch seconds. Treat naive datetimes (SQLite round-trips drop tzinfo) as
    UTC so we never mix a tz-aware in-session row with tz-naive DB rows — that
    mismatch silently shifts timestamps by the local offset and corrupts the
    time-of-detection weighting."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


class AnalyticsService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def _zone_positions(self, building_id: str) -> dict[str, tuple[float, float]]:
        zones = (await self.session.scalars(select(Zone).where(Zone.building_id == building_id))).all()
        return {z.id: (z.pos_x, z.pos_y) for z in zones}

    async def triangulate_incident(
        self, incident: Incident, lookback_seconds: int = 600
    ) -> TriangulationResult | None:
        """Estimate the hazard source for an incident and persist it on the row.

        Considers readings of the incident's hazard sensor type within a recent window:
        latest value per device = concentration, first over-threshold time = detection
        time. A window (rather than `>= opened_ts`) ensures sensors that crossed slightly
        before the incident row was created are still included. Returns None when
        triangulation is not applicable (e.g. water_leak).
        """
        try:
            sensor_type = SensorType(incident.hazard_type)
        except ValueError:
            return None
        th = thresholds_for(sensor_type)
        if th is None:
            return None
        baseline = th.detection

        zones = await self._zone_positions(incident.building_id)

        since = datetime.now(timezone.utc) - timedelta(seconds=lookback_seconds)
        rows = (
            await self.session.scalars(
                select(SensorReading)
                .where(
                    SensorReading.building_id == incident.building_id,
                    SensorReading.sensor_type == incident.hazard_type,
                    SensorReading.ts >= since,
                )
                .order_by(SensorReading.ts.asc())
            )
        ).all()
        if not rows:
            return None

        # per-device: latest value + first over-threshold timestamp + zone
        agg: dict[str, dict] = {}
        for r in rows:
            d = agg.setdefault(r.device_id, {"value": 0.0, "detected_ts": None, "zone_id": r.zone_id})
            d["value"] = r.value  # ascending order -> last assignment is latest
            d["zone_id"] = r.zone_id
            if d["detected_ts"] is None and r.value >= baseline:
                d["detected_ts"] = _epoch(r.ts)

        sensors: list[SensorPoint] = []
        for device_id, d in agg.items():
            x, y = zones.get(d["zone_id"], (0.0, 0.0))
            sensors.append(
                SensorPoint(
                    device_id=device_id,
                    zone_id=d["zone_id"],
                    x=x,
                    y=y,
                    value=d["value"],
                    baseline=baseline,
                    detected_ts=d["detected_ts"],
                )
            )

        result = await offload.triangulate(sensors, zones)
        if result.source_zone_id is None:
            return None

        incident.est_source_zone_id = result.source_zone_id
        incident.est_source_x = result.source_x
        incident.est_source_y = result.source_y
        incident.triangulation_confidence = result.confidence
        incident.triangulation_method = result.method
        incident.triangulation_detail = {
            "n_contributors": result.n_contributors,
            "airflow_applied": result.airflow_applied,
            "contributors": [
                {"device_id": c.device_id, "zone_id": c.zone_id, "value": c.value, "weight": c.weight}
                for c in result.contributors
            ],
        }
        await self._snapshot(incident.id, result, incident.triangulation_detail["contributors"])
        return result

    async def _snapshot(self, incident_id: str, result: TriangulationResult, contributors: list[dict]) -> None:
        """Keep the estimate in the incident's triangulation history unless it repeats the last one."""
        fields = {
            "source_zone_id": result.source_zone_id,
            "source_x": result.source_x,
            "source_y": result.source_y,
            "confidence": result.confidence,
            "method": result.method,
            "n_contributors": result.n_contributors,
            "airflow_applied": result.airflow_applied,
            "contributors": contributors,
        }
        last = await self.session.scalar(
            select(TriangulationSnapshot)
            .where(TriangulationSnapshot.incident_id == incident_id)
            .order_by(TriangulationSnapshot.ts.desc(), TriangulationSnapshot.id.desc())
            .limit(1)
        )
        if last is not None and all(getattr(last, k) == v for k, v in fields.items()):
            return
        self.session.add(TriangulationSnapshot(incident_id=incident_id, **fields))

    async def classify_signature(self, node_id: str, incident_id: str) -> SignatureAssessment | None:
        """Label an air node's recent window and store the assessment (with the shadow
        model's opinion) for the incident. None for nodes that are not air nodes."""
        node = await self.session.get(Node, node_id)
        if node is None or node.kind != NodeKind.air.value:
            return None
        since = datetime.now(timezone.utc) - timedelta(seconds=SIGNATURE_WINDOW_S)
        rows = (
            await self.session.scalars(
                select(NodeStatus)
                .where(NodeStatus.node_id == node_id, NodeStatus.ts >= since)
                .order_by(NodeStatus.ts.asc())
            )
        ).all()
        features = extract_features([parse_snapshot(_epoch(r.ts), r.payload) for r in rows])
        assessment = assess(features)
        shadow = await offload.signature_shadow(features)  # never raises: a failing AI node means here
        if shadow is not None and shadow.label != assessment.label:
            log.info("signature %s: rules %s (%.2f), shadow %s (%.2f)", node_id, assessment.label,
                     assessment.confidence, shadow.label, shadow.confidence)
        self.session.add(SignatureAssessmentRow(
            incident_id=incident_id,
            node_id=node_id,
            label=assessment.label,
            confidence=assessment.confidence,
            scores=assessment.scores,
            evidence=assessment.evidence,
            shadow_label=shadow.label if shadow else None,
            shadow_confidence=shadow.confidence if shadow else None,
            model_version=shadow.model_version if shadow else None,
        ))
        await self.session.flush()  # insert inside the caller's savepoint, not at a later commit
        return assessment

    async def latest_signatures(self, incident_ids: list[str]) -> dict[str, SignatureAssessmentRow]:
        """The newest assessment per incident, in one query (ids are monotonic)."""
        if not incident_ids:
            return {}
        newest = (
            select(func.max(SignatureAssessmentRow.id))
            .where(SignatureAssessmentRow.incident_id.in_(incident_ids))
            .group_by(SignatureAssessmentRow.incident_id)
        )
        rows = (await self.session.scalars(
            select(SignatureAssessmentRow).where(SignatureAssessmentRow.id.in_(newest))
        )).all()
        return {r.incident_id: r for r in rows}

    async def sensor_trust(self, building_id: str, *, hours: int = 24) -> list[dict]:
        """Assess physical node coverage from bounded history without mutating readings or health rows."""
        now = datetime.now(timezone.utc)
        since = now - timedelta(hours=hours)
        reference_cutoff = now - timedelta(minutes=min(60, hours * 15))
        rows = list((await self.session.scalars(
            select(SensorReading)
            .where(SensorReading.building_id == building_id, SensorReading.ts >= since)
            .order_by(SensorReading.ts.desc(), SensorReading.id.desc())
            .limit(TRUST_HISTORY_MAX)
        )).all())
        rows.reverse()
        nodes = list((await self.session.scalars(
            select(Node).where(Node.building_id == building_id).order_by(Node.name, Node.id)
        )).all())
        devices = list((await self.session.scalars(
            select(Device).where(Device.building_id == building_id)
        )).all())
        incidents = list((await self.session.scalars(
            select(Incident).where(
                Incident.building_id == building_id,
                Incident.opened_ts <= now,
                or_(Incident.resolved_ts.is_(None), Incident.resolved_ts >= since),
            )
        )).all())
        incident_ranges = [(_epoch(item.opened_ts), _epoch(item.resolved_ts or now)) for item in incidents]
        by_device: dict[str, list[SensorReading]] = {}
        for row in rows:
            by_device.setdefault(row.device_id, []).append(row)
        known = {device.id: device for device in devices}
        now_s = now.timestamp()
        cutoff_s = reference_cutoff.timestamp()
        out = []
        for node in nodes:
            channels = []
            for device_id in device_ids(node.id, node.kind):
                device = known.get(device_id)
                if device is None:
                    continue
                history = by_device.get(device_id, [])
                times = [_epoch(row.ts) for row in history]
                deltas = [b - a for a, b in zip(times, times[1:]) if b > a]
                interval = median(deltas) if deltas else 15.0
                samples = [
                    AnomalySample(
                        ts=_epoch(row.ts),
                        value=row.value,
                        incident=any(start <= _epoch(row.ts) <= end for start, end in incident_ranges),
                    )
                    for row in history
                ]
                result = assess_channel(
                    samples,
                    now_ts=now_s,
                    interval_s=interval,
                    reference_cutoff_ts=cutoff_s,
                    binary=device.sensor_type == SensorType.water_leak.value,
                )
                seen = _epoch(device.last_seen_ts) if device.last_seen_ts else None
                if not node.online or is_stale(last_seen_ts=seen, now_ts=now_s, interval_s=interval):
                    result = result.__class__("lost", "coverage_lost", result.sample_count, result.input_age_seconds)
                channels.append({
                    "device_id": device_id,
                    "sensor_type": device.sensor_type,
                    "state": result.state,
                    "reason": result.reason,
                    "sample_count": result.sample_count,
                    "input_age_seconds": result.input_age_seconds,
                })
            state = "lost" if any(c["state"] == "lost" for c in channels) else (
                "suspect" if not channels or any(c["state"] == "suspect" for c in channels) else "ok"
            )
            reason = next((c["reason"] for c in channels if c["state"] == state), "insufficient_data" if not channels else "ok")
            out.append({"node_id": node.id, "state": state, "reason": reason, "channels": channels})
        return out

    async def fusion_explanation(self, incident: Incident) -> dict:
        """Recompute an advisory explanation from recent inputs; never changes incident state."""
        now = datetime.now(timezone.utc)
        since = now - timedelta(seconds=FUSION_WINDOW_S)
        q = select(SensorReading).where(
            SensorReading.building_id == incident.building_id,
            SensorReading.ts >= since,
        )
        if incident.primary_zone_id is not None:
            q = q.where(SensorReading.zone_id == incident.primary_zone_id)
        rows = list((await self.session.scalars(
            q.order_by(SensorReading.ts.desc(), SensorReading.id.desc()).limit(FUSION_HISTORY_MAX)
        )).all())
        rows.reverse()
        fresh_after = now.timestamp() - FUSION_FRESH_S
        latest: dict[str, SensorReading] = {}
        for row in rows:
            latest[row.device_id] = row

        def instrument(row: SensorReading) -> str:
            if row.sensor_type == SensorType.particulate.value:
                suffix = row.device_id.rsplit(":", 1)[-1]
                if suffix in {"pm1_0", "pm2_5", "pm10", "particulate"}:
                    return row.device_id.rsplit(":", 1)[0]
            return row.device_id

        elevated: dict[str, SensorReading] = {}
        for row in latest.values():
            thresholds = thresholds_for(SensorType(row.sensor_type)) if row.sensor_type in SensorType._value2member_map_ else None
            if _epoch(row.ts) >= fresh_after and thresholds is not None and (
                row.value >= thresholds.detection or row.edge_state == "alarm"
            ):
                elevated[instrument(row)] = row

        try:
            hazard = SensorType(incident.hazard_type)
        except ValueError:
            hazard = None
        thresholds = thresholds_for(hazard) if hazard is not None else None
        hazard_rows = [row for row in rows if row.sensor_type == incident.hazard_type]
        assessment = classify(
            [ReadingSample(_epoch(row.ts), row.value) for row in hazard_rows],
            detection=thresholds.detection if thresholds else float("inf"),
            critical=thresholds.critical if thresholds else float("inf"),
            clear=thresholds.clear if thresholds else 0.0,
            multi_sensor=len(elevated) >= 2,
            edge_alarm=any(row.edge_state == "alarm" for row in hazard_rows),
        )
        signature = (await self.latest_signatures([incident.id])).get(incident.id)
        supporting = [assessment.reason]
        supporting.extend(f"fresh_{row.sensor_type}:{key}" for key, row in sorted(elevated.items()))
        contradicting: list[str] = []
        missing: list[str] = []
        inputs = []
        for sensor_type in (SensorType.particulate.value, SensorType.co.value, SensorType.combustible_gas.value):
            row = max((item for item in latest.values() if item.sensor_type == sensor_type), key=lambda item: item.ts, default=None)
            if row is None:
                missing.append(sensor_type)
                inputs.append({"name": sensor_type, "age_seconds": None, "status": "missing"})
                continue
            age = max(0.0, now.timestamp() - _epoch(row.ts))
            status = "fresh" if age <= FUSION_FRESH_S else "stale"
            if status == "stale":
                missing.append(sensor_type)
            else:
                th = thresholds_for(SensorType(sensor_type))
                if th is not None and row.value < th.detection:
                    contradicting.append(f"{sensor_type}_below_threshold")
            inputs.append({"name": sensor_type, "age_seconds": age, "status": status})
        overrides = []
        if assessment.reason == "critical_or_edge_alarm":
            overrides.append("critical_or_edge_alarm")
        if signature is not None:
            age = max(0.0, now.timestamp() - _epoch(signature.ts))
            inputs.append({"name": "signature", "age_seconds": age, "status": "fresh" if age <= FUSION_WINDOW_S else "stale"})
            if signature.label in FIRE_LABELS:
                overrides.append("fire_signature")
                supporting.extend(signature.evidence)
            elif signature.label in {"steam", "cooking", "aerosol"}:
                contradicting.extend(signature.evidence)
        if incident.state in {"alarm", "escalation", "evacuation"}:
            overrides.append("incident_already_alarmed")
        items = await evidence_items(self.session, incident, await self.sensor_trust(incident.building_id), now)
        return {
            "incident_id": incident.id,
            "score": assessment.benign_score,
            "score_kind": "benign_likelihood",
            "classification": assessment.classification,
            "assessed_ts": now,
            "fresh_witnesses": len(elevated),
            "supporting_evidence": supporting,
            "contradicting_evidence": contradicting,
            "missing_inputs": missing,
            "active_overrides": overrides,
            "inputs": inputs,
            "evidence_items": items,
        }
