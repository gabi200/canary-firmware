"""Notification service (MVP).

Persists Notification rows (the auditable record of who was told what) and pushes
a live event over WebSocket. Real FCM/APNs/SMS/email/webhook transports plug in
here behind the same interface in a later phase. Always broadcasts the incident
event to the building room so dashboards update; selects human/external recipients
per incident state per ARCHITECTURE.md section 7.
"""

from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import (
    ALARMED_STATES,
    IncidentState,
    NotificationChannel,
    Role,
)
from app.models import (
    AuditLogEntry,
    ExternalIntegration,
    Incident,
    Notification,
    ResidentUnit,
    User,
)
from app.realtime.ws import manager

_HAZARD_LABEL = {
    "combustible_gas": "Gas leak",
    "co": "Carbon monoxide",
    "water_leak": "Water leak",
}

# states that alert residents directly
_RESIDENT_STATES = {
    IncidentState.alarm,
    IncidentState.evacuation,
    IncidentState.resolution,
    IncidentState.false_alarm,
}
# states that notify external integrations (ARC / gas distributor / ISU webhook)
_EXTERNAL_STATES = {
    IncidentState.escalation,
    IncidentState.evacuation,
    IncidentState.resolution,
}


def _message(incident: Incident, state: IncidentState) -> tuple[str, str]:
    hz = _HAZARD_LABEL.get(incident.hazard_type, incident.hazard_type)
    if state == IncidentState.alarm:
        return (f"{hz} ALARM", f"{hz} detected. Prepare to evacuate. Follow guidance.")
    if state == IncidentState.evacuation:
        return (f"EVACUATE NOW — {hz}", "Evacuate via the safe route to the assembly point. Check in when safe.")
    if state == IncidentState.escalation:
        return (f"{hz} escalated", "Incident escalated to monitoring/emergency partners.")
    if state == IncidentState.resolution:
        return (f"{hz} — all clear", "The hazard has cleared. It is safe to return per instructions.")
    if state == IncidentState.false_alarm:
        return (f"{hz} — stand down", "The alert was a false alarm. No action needed.")
    return (f"{hz} — {state.value}", f"Incident is now in state {state.value}.")


class NotificationService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def on_state(self, incident: Incident, state: IncidentState) -> None:
        title, body = _message(incident, state)

        # 1) Always broadcast the live incident event to the building dashboard room.
        await manager.broadcast(
            incident.building_id,
            {
                "type": "incident",
                "incident_id": incident.id,
                "building_id": incident.building_id,
                "state": state.value,
                "hazard_type": incident.hazard_type,
                "severity": incident.severity,
                "primary_zone_id": incident.primary_zone_id,
                "est_source_zone_id": incident.est_source_zone_id,
                "triangulation_confidence": incident.triangulation_confidence,
                "title": title,
                "body": body,
                "ts": datetime.now(timezone.utc).isoformat(),
            },
        )

        # 2) Managers are notified on every transition.
        managers = (
            await self.session.scalars(select(User).where(User.role == Role.hoa_manager.value))
        ).all()
        for m in managers:
            self._add_notification(incident, state, NotificationChannel.web_push, title, body, user_id=m.id)

        # 3) Residents on resident-facing states.
        if state in _RESIDENT_STATES:
            residents = await self._building_residents(incident.building_id)
            for r in residents:
                self._add_notification(incident, state, NotificationChannel.push, title, body, user_id=r.id)

        # 4) External integrations on escalation / evacuation / resolution.
        if state in _EXTERNAL_STATES:
            integrations = (
                await self.session.scalars(
                    select(ExternalIntegration).where(
                        ExternalIntegration.building_id == incident.building_id,
                        ExternalIntegration.active.is_(True),
                    )
                )
            ).all()
            for integ in integrations:
                # ISU webhook only fires where a signed agreement exists.
                if integ.kind == "isu_webhook" and not integ.isu_agreement_signed:
                    continue
                self._add_notification(
                    incident, state, NotificationChannel.external, title, body, integration_id=integ.id
                )

        # 5) Audit the privacy-sensitive identity unlock when the building is alarmed.
        if state in ALARMED_STATES:
            self.session.add(
                AuditLogEntry(
                    incident_id=incident.id,
                    actor="system",
                    action="identity_unlock_for_accounting",
                    target=incident.building_id,
                    identity_unlock=True,
                    detail={"state": state.value},
                )
            )

    async def on_checkin(self, incident: Incident, checkin) -> None:
        await manager.broadcast(
            incident.building_id,
            {
                "type": "checkin",
                "incident_id": incident.id,
                "building_id": incident.building_id,
                "user_id": checkin.user_id,
                "unit_id": checkin.unit_id,
                "status": checkin.status,
                "source": checkin.source,
                "ts": datetime.now(timezone.utc).isoformat(),
            },
        )

    # --- helpers -------------------------------------------------------------
    def _add_notification(
        self,
        incident: Incident,
        state: IncidentState,
        channel: NotificationChannel,
        title: str,
        body: str,
        *,
        user_id: str | None = None,
        integration_id: str | None = None,
    ) -> None:
        self.session.add(
            Notification(
                incident_id=incident.id,
                channel=channel.value,
                recipient_user_id=user_id,
                recipient_integration_id=integration_id,
                severity=incident.severity,
                state=state.value,
                title=title,
                body=body,
                delivered=False,
            )
        )

    async def _building_residents(self, building_id: str) -> list[User]:
        rows = (
            await self.session.execute(
                select(User)
                .join(ResidentUnit, ResidentUnit.user_id == User.id)
                .where(ResidentUnit.building_id == building_id, User.role == Role.resident.value)
                .distinct()
            )
        ).scalars().all()
        return list(rows)
