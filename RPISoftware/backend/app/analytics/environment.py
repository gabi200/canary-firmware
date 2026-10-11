"""Pure environment analysis for hardware nodes (docs/HARDWARE.md section 3).

Turns a node's latest raw status document into plain-language indicators, a
status, a headline and advice, and rolls nodes up into a building summary. No DB,
no I/O, fully deterministic. The output never carries raw measurements (ppm, ADC
counts, ug/m3, degC, %RH, RSSI, distances): the only numbers are the AQI in the
air-quality `detail` and the warm-up countdown in the health `detail`, because
residents receive it.

Text is produced in the request's language (app.i18n.tr, English by default), so
checks on indicator values compare against tr() of the English source string.
"""

from __future__ import annotations

import math
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import NamedTuple

from app.analytics.false_alarm import ReadingSample, _slope
from app.i18n import tr

# levels / statuses
OK = "ok"
ATTENTION = "attention"
DANGER = "danger"
UNKNOWN = "unknown"  # indicator only; counts as ok for node / zone / building status
_SEVERITY = {OK: 0, UNKNOWN: 0, ATTENTION: 1, DANGER: 2}
_STATUS_BY_SEVERITY = (OK, ATTENTION, DANGER)

# A node is stale after 3 missed heartbeats (air publishes every 15 s, water every 60 s).
HEARTBEAT_S = {"air": 15, "water": 60}
STALE_HEARTBEATS = 3

# Trend: least-squares change over the last 30 min, relative to the channel's warn threshold.
TREND_WINDOW_S = 1800
TREND_MIN_POINTS = 3
TREND_MIN_SPAN_S = 120
TREND_FRACTION = 0.1
# (history field, status-document channel, warn-threshold key)
TREND_FIELDS = (
    ("particulate.pm2_5", "particulate", "warn_pm2_5"),
    ("co.ppm", "co", "warn_ppm"),
    ("gas.adc", "gas", "warn_adc"),
)

# Comfort bands (degC / %RH); attention only at the extremes.
COLD_C, WARM_C, DRY_RH, HUMID_RH = 18.0, 26.0, 30.0, 60.0
EXTREME_COLD_C, EXTREME_WARM_C, EXTREME_HUMID_RH = 16.0, 30.0, 70.0

WEAK_RSSI_DBM = -80

# EPA AQI breakpoints: (concentration low, high, index low, high). PM2.5 per the 2024 update.
_PM25_BREAKPOINTS = (
    (0.0, 9.0, 0, 50),
    (9.1, 35.4, 51, 100),
    (35.5, 55.4, 101, 150),
    (55.5, 125.4, 151, 200),
    (125.5, 225.4, 201, 300),
    (225.5, 325.4, 301, 500),
)
_PM10_BREAKPOINTS = (
    (0, 54, 0, 50),
    (55, 154, 51, 100),
    (155, 254, 101, 150),
    (255, 354, 151, 200),
    (355, 424, 201, 300),
    (425, 604, 301, 500),
)
_AQI_BANDS = (
    (50, "Good", OK),
    (100, "Moderate", OK),
    (150, "Unhealthy for sensitive groups", ATTENTION),
    (200, "Unhealthy", ATTENTION),
    (300, "Very unhealthy", DANGER),
)

_LABELS = {
    "air_quality": "Air quality",
    "co": "Carbon monoxide",
    "gas": "Combustible gas",
    "comfort": "Comfort",
    "occupancy": "Occupancy",
    "health": "Sensor health",
    "leak": "Water leak",
    "valve": "Water valve",
}
# device channel grading -> (value, level)
_CHANNEL_STATES = {
    "ok": ("Safe", OK),
    "warning": ("Elevated", ATTENTION),
    "danger": ("Dangerous", DANGER),
    "warmup": ("Warming up", UNKNOWN),
    "fault": ("Sensor fault", ATTENTION),
}
_GRADED = ("ok", "warning", "danger")

_ADVICE_CONNECTION = "Check the sensor's power and Wi-Fi connection"
_ADVICE_WIFI = "Move the sensor closer to the Wi-Fi router"


@dataclass(frozen=True)
class Indicator:
    key: str
    label: str
    level: str  # ok | attention | danger | unknown
    value: str
    detail: str | None = None
    trend: str | None = None  # rising | falling | stable | None


@dataclass(frozen=True)
class NodeAnalysis:
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
    indicators: list[Indicator]


@dataclass(frozen=True)
class OpenIncident:
    state: str
    severity: str
    title: str
    opened_ts: datetime


@dataclass(frozen=True)
class ZoneSummary:
    zone_id: str
    zone_label: str
    status: str
    occupied: bool | None  # None when the zone has no air node reporting presence
    nodes: list[NodeAnalysis]


@dataclass(frozen=True)
class BuildingSummary:
    building_id: str
    generated_ts: datetime
    status: str
    headline: str
    nodes_total: int
    nodes_online: int
    active_incidents: int
    zones: list[ZoneSummary]


# --------------------------------------------------------------------------- #
# Small shared helpers
# --------------------------------------------------------------------------- #
def finite_number(value: object) -> float | None:
    """A finite JSON number as float (bools excluded), else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except OverflowError:  # an absurdly large JSON integer
        return None
    return number if math.isfinite(number) else None


def utc(dt: datetime) -> datetime:
    """Aware UTC datetime. SQLite round-trips drop tzinfo; those values are UTC."""
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)


def _worst(levels: Iterable[str]) -> str:
    return _STATUS_BY_SEVERITY[max((_SEVERITY[level] for level in levels), default=0)]


# --------------------------------------------------------------------------- #
# Air quality index
# --------------------------------------------------------------------------- #
def _aqi(conc: float, table: tuple) -> int:
    for c_lo, c_hi, i_lo, i_hi in table:
        if conc <= c_hi:
            return math.floor((i_hi - i_lo) / (c_hi - c_lo) * (conc - c_lo) + i_lo + 0.5)
    return 500  # beyond the scale


def pm25_aqi(ugm3: float) -> int:
    """EPA AQI for an instant PM2.5 reading (concentration truncated to 0.1 ug/m3)."""
    return _aqi(math.floor(ugm3 * 10 + 1e-9) / 10, _PM25_BREAKPOINTS)


def pm10_aqi(ugm3: float) -> int:
    """EPA AQI for an instant PM10 reading (concentration truncated to 1 ug/m3)."""
    return _aqi(math.floor(ugm3 + 1e-9), _PM10_BREAKPOINTS)


def aqi_category(aqi: int) -> tuple[str, str]:
    """(category, level) for an AQI value."""
    for top, name, level in _AQI_BANDS:
        if aqi <= top:
            return name, level
    return "Hazardous", DANGER


# --------------------------------------------------------------------------- #
# Freshness + trends
# --------------------------------------------------------------------------- #
def is_stale(kind: str, last_seen_ts: datetime | None, now: datetime) -> bool:
    """No status document for 3x the node's heartbeat."""
    if last_seen_ts is None:
        return True
    limit = STALE_HEARTBEATS * HEARTBEAT_S.get(kind, max(HEARTBEAT_S.values()))
    return (utc(now) - utc(last_seen_ts)).total_seconds() > limit


class TrendFit(NamedTuple):
    """A series' least-squares fit, as computed by the database (app.analytics.nodes)."""

    n: int
    span_s: float
    slope: float  # value per second


def trend_from_fit(fit: TrendFit, warn: float | None) -> str | None:
    """rising / falling / stable from a fit, or None without enough history. The fitted
    change across the window is compared with 10 % of `warn`."""
    if warn is None or warn <= 0 or fit.n < TREND_MIN_POINTS or fit.span_s < TREND_MIN_SPAN_S:
        return None
    change = fit.slope * fit.span_s
    if change >= TREND_FRACTION * warn:
        return "rising"
    if change <= -TREND_FRACTION * warn:
        return "falling"
    return "stable"


def trend(points: Sequence[tuple[float, float]], warn: float | None) -> str | None:
    """trend_from_fit of (epoch_s, value) points."""
    if warn is None or warn <= 0 or len(points) < TREND_MIN_POINTS:
        return None
    samples = [ReadingSample(ts=t, value=v) for t, v in sorted(points)]
    return trend_from_fit(TrendFit(len(samples), samples[-1].ts - samples[0].ts, _slope(samples)), warn)


def _trends(doc: dict, history: Mapping[str, object], now: datetime) -> dict[str, str | None]:
    """`history` per field: (epoch_s, value) points, or a TrendFit already limited to the window."""
    since = utc(now).timestamp() - TREND_WINDOW_S
    out: dict[str, str | None] = {}
    for field, channel, warn_key in TREND_FIELDS:
        ch = doc.get(channel)
        warn = finite_number(ch.get(warn_key)) if isinstance(ch, dict) else None
        series = history.get(field, ())
        if isinstance(series, TrendFit):
            out[field] = trend_from_fit(series, warn)
        else:
            out[field] = trend([(t, v) for t, v in series if t >= since], warn)
    return out


# --------------------------------------------------------------------------- #
# Indicators
# --------------------------------------------------------------------------- #
def _indicator(key: str, level: str, value: str, detail: str | None = None, trend_: str | None = None) -> Indicator:
    return Indicator(key, tr(_LABELS[key]), level, value, detail, trend_)


def _no_data(key: str) -> Indicator:
    return _indicator(key, UNKNOWN, tr("No data"))


def _channel(key: str, channel: object, fresh: bool, trend_: str | None) -> Indicator:
    """co / gas: the device's own grading of the channel (not recomputed here)."""
    if not fresh or not isinstance(channel, dict):
        return _no_data(key)
    state = channel.get("state")
    if not isinstance(state, str) or state not in _CHANNEL_STATES:
        return _no_data(key)
    graded = state in _GRADED
    if graded and channel.get("valid", True) is not True:  # gas has no `valid` flag
        return _no_data(key)
    value, level = _CHANNEL_STATES[state]
    return _indicator(key, level, tr(value), None, trend_ if graded else None)


def _air_quality(pm: object, fresh: bool, trend_: str | None) -> Indicator:
    key = "air_quality"
    if not fresh or not isinstance(pm, dict):
        return _no_data(key)
    state = pm.get("state")
    if state == "fault":
        return _indicator(key, ATTENTION, tr("Sensor fault"))
    if pm.get("valid") is not True:
        return _no_data(key)
    indices = [
        index(conc)
        for index, conc in ((pm25_aqi, finite_number(pm.get("pm2_5"))), (pm10_aqi, finite_number(pm.get("pm10"))))
        if conc is not None and conc >= 0
    ]
    if not indices:
        return _no_data(key)
    aqi = max(indices)
    value, level = aqi_category(aqi)
    # The installer's calibration outranks the generic scale; say so instead of showing
    # "Good" in red while the device holds its alarm (e.g. its clear timer after a spike).
    if state == "danger" and level != DANGER:
        value, level = "Particulate alarm", DANGER
    elif state == "warning" and level == OK:
        value, level = "Particulate warning", ATTENTION
    return _indicator(key, level, tr(value), tr("AQI {aqi}", aqi=aqi), trend_)


def _comfort(climate: object, fresh: bool) -> Indicator:
    key = "comfort"
    if not fresh or not isinstance(climate, dict) or climate.get("valid") is not True:
        return _no_data(key)
    t = finite_number(climate.get("temperature_c"))
    rh = finite_number(climate.get("humidity_percent"))
    if t is None or rh is None:
        return _no_data(key)
    parts = []
    if t < COLD_C:
        parts.append("Too cold")
    elif t > WARM_C:
        parts.append("Too warm")
    if rh < DRY_RH:
        parts.append("Too dry")
    elif rh > HUMID_RH:
        parts.append("Too humid")
    extreme = t < EXTREME_COLD_C or t > EXTREME_WARM_C or rh > EXTREME_HUMID_RH
    return _indicator(key, ATTENTION if extreme else OK, ", ".join(map(tr, parts)) or tr("Comfortable"))


def _occupancy(presence: object, fresh: bool) -> Indicator:
    key = "occupancy"
    if fresh and isinstance(presence, dict) and presence.get("valid") is True:
        detected = presence.get("detected")
        if isinstance(detected, bool):
            return _indicator(key, OK, tr("Occupied") if detected else tr("Empty"))
    return _indicator(key, UNKNOWN, tr("Unknown"))


def _health(kind: str, doc: dict, online: bool, stale: bool) -> Indicator:
    key = "health"
    if not online:
        return _indicator(key, ATTENTION, tr("Offline"))
    if stale:
        return _indicator(key, ATTENTION, tr("Stale"))
    wifi = doc.get("wifi")
    rssi = finite_number(wifi.get("rssi")) if isinstance(wifi, dict) else None
    if rssi is not None and rssi < WEAK_RSSI_DBM:
        return _indicator(key, ATTENTION, tr("Weak Wi-Fi"))
    if kind == "air":
        warmup_s = finite_number(doc.get("warmup_remaining_seconds"))
        if warmup_s is not None and warmup_s > 0:
            minutes = math.ceil(min(warmup_s, 86400) / 60)
            return _indicator(key, OK, tr("Warming up"), tr("{minutes} min left", minutes=minutes))
    return _indicator(key, OK, tr("Online"))


def _leak(doc: dict, fresh: bool) -> Indicator:
    key = "leak"
    if not fresh:
        return _no_data(key)
    sensor = doc.get("sensor")
    state = sensor.get("state") if isinstance(sensor, dict) else None
    if not isinstance(sensor, dict) or sensor.get("initialized") is not True or state not in ("wet", "dry"):
        return _indicator(key, UNKNOWN, tr("Sensor not ready"))
    if state == "wet":
        return _indicator(key, DANGER, tr("Leak detected"))
    if doc.get("leak_latched") is True:
        return _indicator(key, ATTENTION, tr("Leak cleared — inspect"))
    return _indicator(key, OK, tr("No leak"))


def _valve(doc: dict) -> Indicator:
    """Last known valve position (an actuator state, kept while the node is quiet)."""
    valve = doc.get("valve")
    applied = valve.get("applied") if isinstance(valve, dict) else None
    if applied == "open":
        return _indicator("valve", OK, tr("Open"))
    if applied == "closed":
        return _indicator("valve", ATTENTION, tr("Closed"))
    return _indicator("valve", UNKNOWN, tr("Unknown"))


# --------------------------------------------------------------------------- #
# Headline + advice: (level, headline, advice) findings in priority order
# --------------------------------------------------------------------------- #
Finding = tuple[str, str, str | None]


def _connection_findings(health: Indicator) -> list[Finding]:
    if health.value == tr("Offline"):
        return [(ATTENTION, tr("Sensor offline"), tr(_ADVICE_CONNECTION))]
    if health.value == tr("Stale"):
        return [(ATTENTION, tr("No recent data from the sensor"), tr(_ADVICE_CONNECTION))]
    return []


def _comfort_advice(value: str) -> str:
    tips = {
        "Too cold": "turn up the heating",
        "Too warm": "cool the room down",
        "Too dry": "use a humidifier",
        "Too humid": "ventilate to lower the humidity",
    }
    return "; ".join(tr(tip) for part, tip in tips.items() if tr(part) in value).capitalize()


def _air_findings(ind: Mapping[str, Indicator]) -> list[Finding]:
    health, co, gas, aq, comfort = (ind[k] for k in ("health", "co", "gas", "air_quality", "comfort"))
    findings = _connection_findings(health)
    if co.level == DANGER:
        findings.append((DANGER, tr("Dangerous carbon monoxide level"), tr("Leave the area now and call 112")))
    if gas.level == DANGER:
        findings.append(
            (DANGER, tr("Gas leak detected"), tr("Do not use flames or switches; leave the area and call 112"))
        )
    if aq.level == DANGER:
        findings.append(
            (DANGER, tr("Hazardous air: smoke or heavy particulates"),
             tr("Check for smoke or fire; if there is a fire, leave and call 112"))
        )
    if co.value == tr("Elevated"):
        findings.append(
            (ATTENTION, tr("Carbon monoxide is elevated"), tr("Open windows and turn off fuel-burning appliances"))
        )
    if gas.value == tr("Elevated"):
        findings.append(
            (ATTENTION, tr("Gas level is elevated"), tr("Ventilate and check the stove and gas connections"))
        )
    if aq.level == ATTENTION and aq.value != tr("Sensor fault"):
        findings.append(
            (ATTENTION, tr("Air quality is unhealthy"),
             tr("Ventilate if the outdoor air is clean, or run an air purifier"))
        )
    if tr("Sensor fault") in (co.value, gas.value, aq.value):
        findings.append((ATTENTION, tr("Sensor fault"), tr("Have the sensor checked by the installer")))
    if comfort.level == ATTENTION:
        headline = tr("Uncomfortable: {conditions}", conditions=comfort.value.lower())
        findings.append((ATTENTION, headline, _comfort_advice(comfort.value)))
    if health.value == tr("Weak Wi-Fi"):
        findings.append((ATTENTION, tr("Weak Wi-Fi signal"), tr(_ADVICE_WIFI)))
    if health.value == tr("Warming up"):
        findings.append((OK, tr("Sensor warming up"), None))
    return findings


def _air_default(ind: Mapping[str, Indicator]) -> str:
    aq = ind["air_quality"].value
    if aq == tr("Good"):
        return tr("Air is good")
    if aq == tr("Moderate"):
        return tr("Air quality is moderate")
    return tr("No air quality data yet")


def _water_findings(ind: Mapping[str, Indicator]) -> list[Finding]:
    health, leak, valve = ind["health"], ind["leak"], ind["valve"]
    findings = _connection_findings(health)
    if leak.value == tr("Leak detected"):
        advice = tr(
            "Water supply was shut off automatically. Fix the leak and dry the sensor, "
            "then reopen the valve on the device."
            if valve.value == tr("Closed")
            else "Shut off the water supply and fix the leak"
        )
        findings.append((DANGER, tr("Water leak detected"), advice))
    elif leak.value == tr("Leak cleared — inspect"):
        findings.append(
            (ATTENTION, tr("Leak cleared — inspect the area"),
             tr("Make sure the leak is fixed and the area is dry, then reopen the valve on the device"))
        )
    elif valve.value == tr("Closed"):
        findings.append(
            (ATTENTION, tr("Water supply is shut off"), tr("Reopen the valve on the device when it is safe"))
        )
    if leak.value == tr("Sensor not ready"):
        findings.append((OK, tr("Leak sensor not ready"), tr("Check that the leak sensor is connected")))
    if health.value == tr("Weak Wi-Fi"):
        findings.append((ATTENTION, tr("Weak Wi-Fi signal"), tr(_ADVICE_WIFI)))
    return findings


def _headline_and_advice(findings: list[Finding], default: str) -> tuple[str, list[str]]:
    """Headline of the first most-severe finding; advice from all findings at that level."""
    if not findings:
        return default, []
    top = max(_SEVERITY[level] for level, _, _ in findings)
    headline = next(text for level, text, _ in findings if _SEVERITY[level] == top)
    advice: list[str] = []
    for level, _, tip in findings:
        if tip and _SEVERITY[level] == top and tip not in advice:
            advice.append(tip)
    return headline, advice


# --------------------------------------------------------------------------- #
# Public entry points
# --------------------------------------------------------------------------- #
def analyze_node(
    *,
    node_id: str,
    kind: str,
    name: str,
    zone_id: str,
    online: bool,
    last_seen_ts: datetime | None,
    status: object,
    now: datetime,
    history: Mapping[str, Sequence[tuple[float, float]] | TrendFit] | None = None,
) -> NodeAnalysis:
    """Analyze one node from its latest raw status document.

    `history` maps trend fields (`co.ppm`, `gas.adc`, `particulate.pm2_5`) to recent
    (epoch_s, value) points; without it trends are None. Stale or offline nodes get
    `No data` on their hazard indicators and at least `attention` status.
    """
    doc = status if isinstance(status, dict) else {}
    stale = is_stale(kind, last_seen_ts, now)
    fresh = online and not stale
    if kind == "air":
        trends = _trends(doc, history or {}, now) if fresh else {}
        indicators = [
            _air_quality(doc.get("particulate"), fresh, trends.get("particulate.pm2_5")),
            _channel("co", doc.get("co"), fresh, trends.get("co.ppm")),
            _channel("gas", doc.get("gas"), fresh, trends.get("gas.adc")),
            _comfort(doc.get("climate"), fresh),
            _occupancy(doc.get("presence"), fresh),
            _health(kind, doc, online, stale),
        ]
        by_key = {i.key: i for i in indicators}
        headline, advice = _headline_and_advice(_air_findings(by_key), _air_default(by_key))
    else:
        indicators = [_leak(doc, fresh), _valve(doc), _health(kind, doc, online, stale)]
        by_key = {i.key: i for i in indicators}
        headline, advice = _headline_and_advice(_water_findings(by_key), tr("No leak"))
    return NodeAnalysis(
        node_id=node_id,
        kind=kind,
        name=name,
        zone_id=zone_id,
        online=online,
        stale=stale,
        last_seen_ts=utc(last_seen_ts) if last_seen_ts is not None else None,
        status=_worst(i.level for i in indicators),
        headline=headline,
        advice=advice,
        indicators=indicators,
    )


_INCIDENT_RANK = {"detection": 1, "verification": 2, "alarm": 3, "escalation": 4, "evacuation": 5}
_INCIDENT_SEVERITY_RANK = {"info": 0, "warning": 1, "critical": 2}
_ALARMED = ("alarm", "escalation", "evacuation")


def summarize_building(
    *,
    building_id: str,
    generated_ts: datetime,
    nodes: Sequence[NodeAnalysis],
    zone_labels: Mapping[str, str],
    incidents: Sequence[OpenIncident],
) -> BuildingSummary:
    """Roll node analyses up into zones and a building status.

    Open incidents drive the status (alarmed -> danger, otherwise attention) and the
    headline; a node in a worse state than the incidents still raises the status, so
    the summary never under-reports. Without incidents the worst zone decides.
    """
    by_zone: dict[str, list[NodeAnalysis]] = {}
    for node in nodes:
        by_zone.setdefault(node.zone_id, []).append(node)

    zones: list[ZoneSummary] = []
    def label(zone_id: str) -> str:
        return zone_labels.get(zone_id) or zone_id

    for zone_id in sorted(by_zone, key=lambda z: (label(z), z)):
        members = sorted(by_zone[zone_id], key=lambda n: (n.name, n.node_id))
        occupancy = [i.value for n in members if n.kind == "air" for i in n.indicators if i.key == "occupancy"]
        occupied = True if tr("Occupied") in occupancy else False if tr("Empty") in occupancy else None
        zones.append(
            ZoneSummary(
                zone_id=zone_id,
                zone_label=label(zone_id),
                status=_worst(n.status for n in members),
                occupied=occupied,
                nodes=members,
            )
        )

    ordered = [n for z in zones for n in z.nodes]
    worst_node = max(ordered, key=lambda n: _SEVERITY[n.status], default=None)
    node_status = worst_node.status if worst_node is not None else OK
    if incidents:
        top = max(
            incidents,
            key=lambda i: (
                _INCIDENT_RANK.get(i.state, 0),
                _INCIDENT_SEVERITY_RANK.get(i.severity, 0),
                utc(i.opened_ts),
            ),
        )
        incident_status = DANGER if any(i.state in _ALARMED for i in incidents) else ATTENTION
        status, headline = _worst((incident_status, node_status)), top.title
    elif worst_node is None:
        status, headline = ATTENTION, tr("No sensors connected")
    else:
        status = node_status
        headline = worst_node.headline if node_status != OK else tr("All clear")

    return BuildingSummary(
        building_id=building_id,
        generated_ts=utc(generated_ts),
        status=status,
        headline=headline,
        nodes_total=len(nodes),
        nodes_online=sum(1 for n in nodes if n.online),
        active_incidents=len(incidents),
        zones=zones,
    )
