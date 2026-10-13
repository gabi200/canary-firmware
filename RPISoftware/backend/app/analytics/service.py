"""Analytics service: runs triangulation and the hazard signature classifier from live DB state.

The pure estimates (triangulation, the signature shadow model) go through app.ai.offload: the AI
node computes them in three-Pi mode, this process otherwise. The signature rules, which may hold
or release an escalation, always run here.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai import offload
from app.analytics.signature.features import extract_features, parse_snapshot
from app.analytics.signature.rules import SignatureAssessment, assess
from app.analytics.triangulation import SensorPoint, TriangulationResult
from app.detection.thresholds import thresholds_for
from app.enums import NodeKind, SensorType
from app.models import Incident, Node, NodeStatus, SensorReading, SignatureAssessmentRow, TriangulationSnapshot, Zone

log = logging.getLogger("canary.signature")

# Seconds of an air node's status documents the signature classifier looks at.
SIGNATURE_WINDOW_S = 600


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
