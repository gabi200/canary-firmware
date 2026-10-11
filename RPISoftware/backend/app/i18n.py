"""Romanian / English for backend-generated, user-facing text.

REST: clients send `Accept-Language`; a value starting with `ro` selects Romanian,
anything else (or none) English (tr). Stored notifications use each recipient's own
preference (user_prefs, default Romanian; translate). WebSocket events stay English.
The English source strings are the keys; templated strings are looked up by their
`str.format` template and formatted after translation, so whole sentences are
translated, never fragments. Text without a translation passes through unchanged.
"""

from __future__ import annotations

from contextvars import ContextVar

from starlette.datastructures import Headers
from starlette.types import ASGIApp, Receive, Scope, Send

_lang: ContextVar[str] = ContextVar("canary_lang", default="en")
LANGUAGES = ("ro", "en")
DEFAULT_USER_LANGUAGE = "ro"  # a user's notifications when they have not chosen one

RO: dict[str, str] = {
    # indicator labels
    "Air quality": "Calitatea aerului",
    "Carbon monoxide": "Monoxid de carbon",
    "Combustible gas": "Gaz combustibil",
    "Comfort": "Confort",
    "Occupancy": "Ocupare",
    "Sensor health": "Starea senzorului",
    "Water leak": "Scurgere de apă",
    "Water valve": "Robinet de apă",
    # indicator values
    "No data": "Fără date",
    "Sensor fault": "Senzor defect",
    "Good": "Bună",
    "Moderate": "Moderată",
    "Unhealthy for sensitive groups": "Nesănătoasă pentru grupurile sensibile",
    "Unhealthy": "Nesănătoasă",
    "Very unhealthy": "Foarte nesănătoasă",
    "Hazardous": "Periculoasă",
    "Particulate alarm": "Alarmă de particule",
    "Particulate warning": "Avertizare de particule",
    "AQI {aqi}": "AQI {aqi}",
    "Safe": "Sigur",
    "Elevated": "Ridicat",
    "Dangerous": "Periculos",
    "Warming up": "Se încălzește",
    "Comfortable": "Confortabil",
    "Too cold": "Prea frig",
    "Too warm": "Prea cald",
    "Too dry": "Prea uscat",
    "Too humid": "Prea umed",
    "Occupied": "Ocupat",
    "Empty": "Liber",
    "Unknown": "Necunoscut",
    "Online": "Online",
    "Offline": "Deconectat",
    "Stale": "Date învechite",
    "Weak Wi-Fi": "Wi-Fi slab",
    "{minutes} min left": "încă {minutes} min",
    "Sensor not ready": "Senzor nepregătit",
    "Leak detected": "Scurgere detectată",
    "Leak cleared — inspect": "Scurgere oprită — verificați",
    "No leak": "Nicio scurgere",
    "Open": "Deschis",
    "Closed": "Închis",
    # node headlines
    "Sensor offline": "Senzor deconectat",
    "No recent data from the sensor": "Nu există date recente de la senzor",
    "Dangerous carbon monoxide level": "Nivel periculos de monoxid de carbon",
    "Gas leak detected": "Scurgere de gaz detectată",
    "Hazardous air: smoke or heavy particulates": "Aer periculos: fum sau multe particule",
    "Carbon monoxide is elevated": "Nivel ridicat de monoxid de carbon",
    "Gas level is elevated": "Nivel ridicat de gaz",
    "Air quality is unhealthy": "Calitatea aerului e nesănătoasă",
    "Uncomfortable: {conditions}": "Disconfort: {conditions}",
    "Weak Wi-Fi signal": "Semnal Wi-Fi slab",
    "Sensor warming up": "Senzorul se încălzește",
    "Air is good": "Calitatea aerului e bună",
    "Air quality is moderate": "Calitatea aerului e moderată",
    "No air quality data yet": "Încă nu există date despre calitatea aerului",
    "Water leak detected": "Scurgere de apă detectată",
    "Leak cleared — inspect the area": "Scurgere oprită — verificați zona",
    "Water supply is shut off": "Alimentarea cu apă e oprită",
    "Leak sensor not ready": "Senzorul de scurgere nu e pregătit",
    # advice
    "Check the sensor's power and Wi-Fi connection": "Verificați alimentarea senzorului și conexiunea Wi-Fi",
    "Move the sensor closer to the Wi-Fi router": "Mutați senzorul mai aproape de routerul Wi-Fi",
    "Leave the area now and call 112": "Părăsiți imediat zona și sunați la 112",
    "Do not use flames or switches; leave the area and call 112":
        "Nu folosiți flacără deschisă sau întrerupătoare; părăsiți zona și sunați la 112",
    "Check for smoke or fire; if there is a fire, leave and call 112":
        "Verificați dacă există fum sau foc; dacă e un incendiu, ieșiți și sunați la 112",
    "Open windows and turn off fuel-burning appliances":
        "Deschideți ferestrele și opriți aparatele care ard combustibil",
    "Ventilate and check the stove and gas connections": "Aerisiți și verificați aragazul și racordurile de gaz",
    "Ventilate if the outdoor air is clean, or run an air purifier":
        "Aerisiți dacă aerul de afară e curat sau porniți un purificator de aer",
    "Have the sensor checked by the installer": "Cereți instalatorului să verifice senzorul",
    "turn up the heating": "măriți încălzirea",
    "cool the room down": "răciți încăperea",
    "use a humidifier": "folosiți un umidificator",
    "ventilate to lower the humidity": "aerisiți pentru a reduce umiditatea",
    "Water supply was shut off automatically. Fix the leak and dry the sensor, then reopen the valve on the device.":
        "Alimentarea cu apă a fost oprită automat. Remediați scurgerea și uscați senzorul, "
        "apoi redeschideți robinetul de pe dispozitiv.",
    "Shut off the water supply and fix the leak": "Opriți alimentarea cu apă și remediați scurgerea",
    "Make sure the leak is fixed and the area is dry, then reopen the valve on the device":
        "Asigurați-vă că scurgerea e remediată și zona e uscată, apoi redeschideți robinetul de pe dispozitiv",
    "Reopen the valve on the device when it is safe": "Redeschideți robinetul de pe dispozitiv când e sigur",
    "Check that the leak sensor is connected": "Verificați dacă senzorul de scurgere e conectat",
    # building summary
    "All clear": "Totul e în regulă",
    "No sensors connected": "Niciun senzor conectat",
    # incident titles (building summary headline)
    "Gas leak": "Scurgere de gaz",
    "Smoke / particulates": "Fum / particule",
    "{hazard} ALARM": "ALARMĂ: {hazard}",
    "EVACUATE NOW — {hazard}": "EVACUAȚI ACUM — {hazard}",
    "{hazard} escalated": "{hazard} — incident escaladat",
    "{hazard} — all clear": "{hazard} — totul e în regulă",
    "{hazard} — stand down": "{hazard} — alarmă anulată",
    "normal": "normal",
    "detection": "detectare",
    "verification": "verificare",
    # notification bodies (stored per recipient, in their language)
    "{hazard} detected. Prepare to evacuate. Follow guidance.":
        "Pericol detectat: {hazard}. Pregătiți-vă de evacuare și urmați instrucțiunile.",
    "Water leak detected. If a shut-off valve is fitted, it closed automatically. "
    "Avoid the area and check the unit.":
        "Scurgere de apă detectată. Dacă este montat un robinet de închidere, acesta s-a închis automat. "
        "Evitați zona și verificați apartamentul.",
    "Smoke or heavy particulates detected. Check for smoke or fire and ventilate if safe. "
    "If there is a fire, leave and call 112.":
        "Fum sau multe particule detectate. Verificați dacă există fum sau foc și aerisiți dacă e sigur. "
        "Dacă e un incendiu, ieșiți și sunați la 112.",
    "Evacuate via the safe route to the assembly point. Check in when safe.":
        "Evacuați pe traseul sigur până la punctul de adunare. Confirmați în aplicație când sunteți în siguranță.",
    "Incident escalated to monitoring/emergency partners.":
        "Incidentul a fost transmis dispeceratului de monitorizare și urgență.",
    "The hazard has cleared. It is safe to return per instructions.":
        "Pericolul a trecut. Vă puteți întoarce conform instrucțiunilor.",
    "The leak sensor is dry again. Once the leak is fixed, reopen the shut-off valve if one is fitted.":
        "Senzorul de scurgere e din nou uscat. După remedierea scurgerii, redeschideți robinetul de închidere, "
        "dacă există.",
    "Particulate levels are back to normal.": "Nivelul de particule a revenit la normal.",
    "The alert was a false alarm. No action needed.": "Alerta a fost o alarmă falsă. Nu e nevoie de nicio acțiune.",
    "Incident is now in state {state}.": "Incidentul este acum în starea: {state}.",
    "alarm": "alarmă",
    "escalation": "escaladare",
    "evacuation": "evacuare",
    "resolution": "rezolvat",
    "false_alarm": "alarmă falsă",
}


def language(accept_language: str | None) -> str:
    """`ro` when the header starts with `ro` (e.g. `ro`, `ro-RO,en;q=0.5`), else `en`."""
    return "ro" if (accept_language or "").strip().lower().startswith("ro") else "en"


def translate(lang: str, text: str, **values: object) -> str:
    """`text` in `lang` (ro | en), then formatted with `values`."""
    template = RO.get(text, text) if lang == "ro" else text
    return template.format(**values) if values else template


def tr(text: str, **values: object) -> str:
    """`text` in the current request's language, then formatted with `values`."""
    return translate(_lang.get(), text, **values)


class LanguageMiddleware:
    """Sets the language for one HTTP request from its `Accept-Language` header."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        token = _lang.set(language(Headers(scope=scope).get("accept-language")))
        try:
            await self.app(scope, receive, send)
        finally:
            _lang.reset(token)
