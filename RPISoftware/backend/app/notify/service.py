"""Notification service (MVP).

Persists Notification rows (the auditable record of who was told what), each in its
recipient's language (user_prefs, default Romanian), and pushes a live event over
WebSocket (English, unchanged). Real FCM/APNs/SMS/email transports plug in here behind
the same interface in a later phase. Always broadcasts the incident event to the
building room so dashboards update; selects human/external recipients per incident
state per ARCHITECTURE.md section 7, and sends the signed escalation webhook
(app.notify.escalation) on the external states.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone
from functools import partial

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.enums import (
    ALARMED_STATES,
    IncidentState,
    NotificationChannel,
    Role,
)
from app.i18n import DEFAULT_USER_LANGUAGE, tr, translate
from app.models import (
    AuditLogEntry,
    ExternalIntegration,
    Incident,
    Notification,
    ResidentUnit,
    User,
    UserPref,
)
from app.notify import escalation
from app.realtime.ws import manager

_HAZARD_LABEL = {
    "combustible_gas": "Gas leak",
    "co": "Carbon monoxide",
    "water_leak": "Water leak",
    "particulate": "Smoke / particulates",
}

# Resident guidance for hazards that never auto-evacuate: telling people to
# "prepare to evacuate" for a leak or a smoky kitchen would be wrong.
_ALARM_BODY = {
    "water_leak": "Water leak detected. If a shut-off valve is fitted, it closed automatically. "
    "Avoid the area and check the unit.",
    "particulate": "Smoke or heavy particulates detected. Check for smoke or fire and ventilate if safe. "
    "If there is a fire, leave and call 112.",
}
_CLEAR_BODY = {
    "water_leak": "The leak sensor is dry again. Once the leak is fixed, reopen the shut-off valve if one is fitted.",
    "particulate": "Particulate levels are back to normal.",
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


def _english(text: str, **values: str) -> str:
    return text.format(**values) if values else text


Translator = Callable[..., str]


def _message(incident: Incident, state: IncidentState, t: Translator = _english) -> tuple[str, str]:
    """(title, body) through the translator `t`: English for WebSocket events and external
    integrations, each recipient's language for their notification, the request's for the
    REST summary (app.i18n.tr)."""
    hz = t(_HAZARD_LABEL.get(incident.hazard_type, incident.hazard_type))
    if state == IncidentState.alarm:
        body = _ALARM_BODY.get(incident.hazard_type, "{hazard} detected. Prepare to evacuate. Follow guidance.")
        return (t("{hazard} ALARM", hazard=hz), t(body, hazard=hz))
    if state == IncidentState.evacuation:
        return (
            t("EVACUATE NOW — {hazard}", hazard=hz),
            t("Evacuate via the safe route to the assembly point. Check in when safe."),
        )
    if state == IncidentState.escalation:
        return (t("{hazard} escalated", hazard=hz), t("Incident escalated to monitoring/emergency partners."))
    if state == IncidentState.resolution:
        body = _CLEAR_BODY.get(incident.hazard_type, "The hazard has cleared. It is safe to return per instructions.")
        return (t("{hazard} — all clear", hazard=hz), t(body))
    if state == IncidentState.false_alarm:
        return (t("{hazard} — stand down", hazard=hz), t("The alert was a false alarm. No action needed."))
    return (t("{hazard} — {state}", hazard=hz, state=t(state.value)),
            t("Incident is now in state {state}.", state=t(state.value)))


def incident_title(incident: Incident) -> str:
    """The resident-facing title for an incident in its current state, in the request's language."""
    return _message(incident, IncidentState(incident.state), tr)[0]


class NotificationService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def on_state(self, incident: Incident, state: IncidentState) -> None:
        title, body = _message(incident, state)  # English: WebSocket + external integrations
        by_language: dict[str, tuple[str, str]] = {}

        def message_for(lang: str) -> tuple[str, str]:
            if lang not in by_language:
                by_language[lang] = _message(incident, state, partial(translate, lang))
            return by_language[lang]

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

        # 2) Managers are notified on every transition; 3) residents on resident-facing states.
        managers = (
            await self.session.scalars(select(User).where(User.role == Role.hoa_manager.value))
        ).all()
        residents = await self._building_residents(incident.building_id) if state in _RESIDENT_STATES else []
        languages = await self._languages([u.id for u in (*managers, *residents)])
        for channel, people in ((NotificationChannel.web_push, managers), (NotificationChannel.push, residents)):
            for person in people:
                own_title, own_body = message_for(languages.get(person.id, DEFAULT_USER_LANGUAGE))
                self._add_notification(incident, state, channel, own_title, own_body, user_id=person.id)

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
            # signed webhook to the ARC / 112 partner, sent after this transaction commits
            await escalation.queue(self.session, incident, state)

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

    async def _languages(self, user_ids: list[str]) -> dict[str, str]:
        if not user_ids:
            return {}
        rows = await self.session.execute(
            select(UserPref.user_id, UserPref.language).where(UserPref.user_id.in_(user_ids))
        )
        return dict(rows.all())

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
