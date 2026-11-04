#!/usr/bin/env python3
"""Many Canary rooms in one process: a whole building of simulated ESP32 nodes.

Every room of a JSON config (rooms.demo.json, rooms.small.json) gets its own
firmware-accurate air and/or water node from hw_sim.py: same topics, status
documents, heartbeats, last will 'offline', and the firmware commands (TEST /
SILENCE on <base>/buzzer/set, OPEN / CLOSE on <base>/valve/set, answered on
<base>/command/result), so the dashboard's and the app's hardware test buttons
work. Base topics default to air-<room> / water-<room> (from the zone id:
zone_bath_12 -> air-bath-12, water-bath-12).

At start it uses the hub's REST API (--hub / HUB_URL, nothing else):
  1. dev login (POST /api/v1/auth/token, user admin);
  2. creates the config's zones the hub does not have yet (admin API
     POST /api/v1/admin/buildings/{id}/zones; units listed under "units" in the
     config are created too if missing). A zone that cannot be created is skipped;
  3. starts the nodes, waits until the hub registered them and moves each one
     into its room (PATCH /api/v1/nodes/{id}: zone_id + name, e.g. "Bucătărie · aer").

While it runs, type a line (in Docker: docker compose attach building-sim):
    bucatarie 12 gaz       the kitchen of Ap. 12 plays the gas scenario
    baie 12 scurgere       bath 12: water leak (valve closes, leak latched)
    baie 12 deschide       valve OPEN, clears the latch (also: inchide, test, liniste)
    toate normal           every room back to normal
    list | help | quit
A room is its zone id (zone_kitchen), the id without "zone_" (kitchen, bath_12)
or its label, with the flat when several flats have it (Hol, "baie 12", "bucatarie ap 13");
case and diacritics do not matter.

Examples:
    python building_sim.py --config rooms.small.json
    python building_sim.py --config rooms.demo.json --fast --scenario kitchen=gas --scenario bath_12=leak
    docker compose --profile sim run --rm building-sim
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import signal
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import paho.mqtt.client as mqtt

import hw_sim
from hw_sim import AirNode, Clock, ConnectError, Scenario, Sim, log

ZONE_KINDS = ("kitchen", "living_room", "bedroom", "bathroom", "hallway", "stairwell", "boiler", "other")
NODE_KINDS = ("air", "water")
NODE_NAMES = {"air": "aer", "water": "apă"}            # hub node name: "<label> · aer"
ROOM_KEYS = {"zone_id", "label", "unit_id", "kind", "pos", "nodes", "scenario", "air_base", "water_base"}
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# Romanian names for the hw_sim scenarios (the English ones work as well).
SCENARIO_ALIASES = {
    "normala": "normal", "gaz": "gas", "monoxid": "co", "fum": "smoke", "scurgere": "leak",
    "inundatie": "leak", "apa": "leak", "prezenta": "presence", "deconectat": "offline",
    "repornire": "reboot", "restart": "reboot", "toate": "all",
}
# The nodes a scenario drives; a room without them cannot play it.
SCENARIO_NEEDS: dict[str, set[str]] = {
    "normal": set(), "co": {"air"}, "gas": {"air"}, "smoke": {"air"}, "leak": {"water"},
    "presence": {"air"}, "offline": {"air"}, "reboot": set(), "all": {"air", "water"},
}
# Firmware commands the console sends, the way the hub does: (node kind, topic suffix, payload).
ACTIONS: dict[str, tuple[tuple[str, str, str], ...]] = {
    "test": (("air", "buzzer/set", "TEST"),),
    "silence": (("air", "buzzer/set", "SILENCE"), ("water", "buzzer/set", "SILENCE")),
    "open": (("water", "valve/set", "OPEN"),),
    "close": (("water", "valve/set", "CLOSE"),),
}
ACTION_ALIASES = {"liniste": "silence", "deschide": "open", "inchide": "close"}
EVERY_ROOM = {"all", "toate", "*"}

HELP = """\
one command per line; <room> = zone id (kitchen, bath_12) or label + flat (bucatarie 12, baie 13, hol):
  <room> <scenario>   normal | gaz/gas | co | fum/smoke | scurgere/leak | prezenta/presence
                      | offline | repornire/reboot | toate/all
  <room> <command>    test | liniste/silence | deschide/open | inchide/close (valve),
                      sent to the node like the hub sends them
  toate <scenario>    every room that has the node(s) the scenario needs (also: all, *)
  list                rooms, scenarios, alarm and valve states
  quit                stop: every node goes offline, like unplugging it"""


class ConfigError(ValueError):
    pass


class HubError(Exception):
    pass


class HubUnreachable(HubError):
    pass


# ============================================================ names and matching


def norm(text: str) -> str:
    """Lowercase, no diacritics, other characters as single spaces: 'Bucătărie_2' -> 'bucatarie 2'."""
    plain = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))
    return " ".join(re.findall(r"[a-z0-9]+", plain.lower()))


def topic_slug(text: str) -> str:
    return "-".join(re.findall(r"[a-z0-9]+", text.lower()))


def zone_suffix(zone_id: str) -> str:
    return zone_id[5:] if zone_id.startswith("zone_") and len(zone_id) > 5 else zone_id


def scenario_name(word: object) -> str:
    key = norm(word) if isinstance(word, str) else ""
    name = SCENARIO_ALIASES.get(key, key)
    if name not in SCENARIO_NEEDS:
        raise ConfigError(f"unknown scenario {word!r} (use {', '.join(SCENARIO_NEEDS)} "
                          f"or {', '.join(SCENARIO_ALIASES)})")
    return name


def missing_nodes(scenario: str, nodes: tuple[str, ...]) -> list[str]:
    return sorted(SCENARIO_NEEDS[scenario] - set(nodes))


# ============================================================ config


@dataclass(eq=False)
class Room:
    zone_id: str
    label: str
    unit_id: str
    kind: str
    pos: tuple[float, float]
    nodes: tuple[str, ...]
    scenario: str = "normal"
    bases: dict[str, str] = field(default_factory=dict)  # node kind -> MQTT base topic
    hub_zone_id: str | None = None                       # the zone's id in the hub, once known
    unit_label: str | None = None                        # "Ap. 12", from the config's "units"

    @property
    def short(self) -> str:
        return zone_suffix(self.zone_id)

    def keys(self) -> set[str]:
        keys = {norm(self.zone_id), norm(self.short), norm(self.label)}
        if self.unit_label:  # every flat has a "Baie": "baie 12" / "baie ap 12" picks one
            keys |= {norm(f"{self.label} {self.unit_label}"),
                     norm(" ".join([self.label, *re.findall(r"\d+", self.unit_label)]))}
        return keys

    @property
    def title(self) -> str:
        return f"{self.label} · {self.unit_label}" if self.unit_label else self.label


@dataclass
class Config:
    building_id: str
    rooms: list[Room]
    units: dict[str, dict]  # config unit id -> {"label", "floor_id", "kind"}: created if missing


def _ident(value: object, where: str) -> str:
    if not isinstance(value, str) or not ID_RE.match(value):
        raise ConfigError(f"{where}: expected an id of 1-64 letters, digits, '_' or '-', got {value!r}")
    return value


def _label(value: object, where: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > 60:
        raise ConfigError(f"{where}: expected a label of 1-60 characters, got {value!r}")
    return value.strip()


def parse_room(data: object, index: int) -> Room:
    if not isinstance(data, dict):
        raise ConfigError(f"rooms[{index}]: expected an object")
    zone_id = _ident(data.get("zone_id"), f"rooms[{index}].zone_id")
    where = f"room {zone_id}"
    unknown = sorted(k for k in data if k not in ROOM_KEYS and not k.startswith("_"))
    if unknown:
        raise ConfigError(f"{where}: unknown key(s) {', '.join(unknown)} (known: {', '.join(sorted(ROOM_KEYS))})")
    label = _label(data.get("label"), f"{where}: label")
    unit_id = _ident(data.get("unit_id"), f"{where}: unit_id")
    kind = data.get("kind")
    if kind not in ZONE_KINDS:
        raise ConfigError(f"{where}: kind must be one of {', '.join(ZONE_KINDS)}, got {kind!r}")
    pos = data.get("pos")
    if not (isinstance(pos, list) and len(pos) == 2
            and all(isinstance(v, (int, float)) and not isinstance(v, bool) and -1000 <= v <= 1000 for v in pos)):
        raise ConfigError(f"{where}: pos must be [x, y] in metres (-1000..1000), got {pos!r}")
    nodes = data.get("nodes", ["air", "water"])
    if not (isinstance(nodes, list) and nodes and all(n in NODE_KINDS for n in nodes) and len(set(nodes)) == len(nodes)):
        raise ConfigError(f"{where}: nodes must list \"air\" and/or \"water\", got {nodes!r}")
    try:
        scenario = scenario_name(data.get("scenario", "normal"))
    except ConfigError as exc:
        raise ConfigError(f"{where}: {exc}") from None
    if missing_nodes(scenario, tuple(nodes)):
        raise ConfigError(f"{where}: scenario {scenario} needs a {'+'.join(missing_nodes(scenario, tuple(nodes)))} node")
    bases = {}
    for node in nodes:
        base = data.get(f"{node}_base") or f"{node}-{topic_slug(zone_suffix(zone_id))}"
        try:
            bases[node] = hw_sim.valid_base(base) if isinstance(base, str) else hw_sim.valid_base("")
        except argparse.ArgumentTypeError as exc:
            raise ConfigError(f"{where}: {node}_base {base!r}: {exc}") from None
    return Room(zone_id, label, unit_id, kind, (float(pos[0]), float(pos[1])), tuple(nodes), scenario, bases)


def parse_config(data: object) -> Config:
    if not isinstance(data, dict):
        raise ConfigError("the config must be a JSON object with \"building_id\" and \"rooms\"")
    unknown = sorted(k for k in data if k not in ("building_id", "rooms", "units") and not k.startswith("_"))
    if unknown:
        raise ConfigError(f"unknown top-level key(s) {', '.join(unknown)} (known: building_id, rooms, units)")
    building_id = _ident(data.get("building_id"), "building_id")
    units: dict[str, dict] = {}
    for i, unit in enumerate(data.get("units") or []):
        if not isinstance(unit, dict):
            raise ConfigError(f"units[{i}]: expected an object")
        unit_id = _ident(unit.get("unit_id"), f"units[{i}].unit_id")
        kind = unit.get("kind", "residential")
        if kind not in ("residential", "common"):
            raise ConfigError(f"unit {unit_id}: kind must be residential or common, got {kind!r}")
        units[unit_id] = {"label": _label(unit.get("label"), f"unit {unit_id}: label"),
                          "floor_id": _ident(unit.get("floor_id"), f"unit {unit_id}: floor_id"), "kind": kind}
    rooms_data = data.get("rooms")
    if not isinstance(rooms_data, list) or not rooms_data:
        raise ConfigError("rooms: expected a non-empty list")
    rooms = [parse_room(r, i) for i, r in enumerate(rooms_data)]
    for room in rooms:
        room.unit_label = units.get(room.unit_id, {}).get("label")
    zones: set[str] = set()
    topics: dict[str, str] = {}  # the hub's node id (slug of the base) -> who uses it
    for room in rooms:
        if room.zone_id in zones:
            raise ConfigError(f"room {room.zone_id}: zone_id used twice")
        zones.add(room.zone_id)
        for node, base in room.bases.items():
            slug = topic_slug(base)
            if slug in topics:
                raise ConfigError(f"room {room.zone_id}: {node} base topic {base!r} clashes with {topics[slug]}; "
                                  f"every device needs its own (set \"{node}_base\")")
            topics[slug] = f"{base!r} of room {room.zone_id}"
    return Config(building_id, rooms, units)


def apply_base_prefix(rooms: list[Room], prefix: str) -> None:
    """Prepend prefix to every base, so the hub, the pre-flight and the nodes all use the same names."""
    if not prefix:
        return
    for room in rooms:
        for node, base in room.bases.items():
            try:
                room.bases[node] = hw_sim.valid_base(prefix + base)
            except argparse.ArgumentTypeError as exc:
                raise ConfigError(f"room {room.zone_id}: {node} base {prefix + base!r}: {exc}") from None


def load_config(path: str) -> Config:
    file = Path(path)
    if not file.is_absolute() and not file.exists() and (Path(__file__).parent / file).exists():
        file = Path(__file__).parent / file  # e.g. --config rooms.small.json from another directory
    try:
        data = json.loads(file.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"cannot read {path}: {exc.strerror}") from None
    except ValueError as exc:
        raise ConfigError(f"{path} is not valid JSON: {exc}") from None
    try:
        return parse_config(data)
    except ConfigError as exc:
        raise ConfigError(f"{path}: {exc}") from None


def match_rooms(rooms: list[Room], query: str) -> list[Room]:
    """The rooms a name refers to: every room for all / toate / *, else exactly one room by
    zone id, id without "zone_" or label (case and diacritics ignored; a unique prefix works).
    Raises LookupError when no room or more than one room matches."""
    if query.strip().lower() in EVERY_ROOM:
        return list(rooms)
    q = norm(query)
    if not q:
        raise LookupError("which room? a zone id (kitchen, bath_12) or a label (bucatarie)")
    found = [r for r in rooms if q in r.keys()]
    if not found:
        found = [r for r in rooms if any(k.startswith(q) for k in r.keys())]
    if not found:
        raise LookupError(f"no room {query!r} (type list to see them)")
    if len(found) > 1:
        names = ", ".join(f"{r.short} ({r.title})" for r in found)
        raise LookupError(f"{query!r} matches {len(found)} rooms: {names}; add the flat (baie 12) or use the id")
    return found


def select_rooms(rooms: list[Room], only: str) -> list[Room]:
    """--only kitchen,bath_12: those rooms, in config order."""
    wanted: set[int] = set()
    for query in only.split(","):
        if query.strip():
            try:
                wanted.update(id(r) for r in match_rooms(rooms, query))
            except LookupError as exc:
                raise ConfigError(f"--only: {exc}") from None
    if not wanted:
        raise ConfigError("--only: name at least one room")
    return [r for r in rooms if id(r) in wanted]


def parse_overrides(items: list[str], rooms: list[Room]) -> dict[str, str]:
    """--scenario ROOM=SCENARIO (ROOM may be all); a bare SCENARIO means every room.
    Returns zone_id -> scenario."""
    out: dict[str, str] = {}
    for item in items:
        target, sep, word = item.partition("=")
        if not sep:
            target, word = "all", item
        if not target.strip() or not word.strip():
            raise ConfigError(f"--scenario {item!r}: use ROOM=SCENARIO, e.g. kitchen=gas")
        try:
            name = scenario_name(word)
            targets = match_rooms(rooms, target)
        except (ConfigError, LookupError) as exc:
            raise ConfigError(f"--scenario {item!r}: {exc}") from None
        for room in targets:
            missing = missing_nodes(name, room.nodes)
            if missing and len(targets) == 1:
                raise ConfigError(f"--scenario {item!r}: room {room.short} has no {'+'.join(missing)} node")
            if not missing:
                out[room.zone_id] = name
    return out


# ============================================================ hub REST API (stdlib only)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102 - never leave the hub
        return None


def detail(payload: object) -> str:
    if isinstance(payload, dict) and "detail" in payload:
        payload = payload["detail"]
    return str(payload)[:200]


class Hub:
    """The hub's REST API at one URL: no proxies, no redirects, nothing else is contacted."""

    def __init__(self, url: str, user: str = "admin", timeout: float = 10.0) -> None:
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise HubError(f"hub URL {url!r}: expected e.g. http://localhost:8000")
        self.url = url.rstrip("/")
        self.user = user
        self.timeout = timeout
        self.token: str | None = None
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)

    def call(self, method: str, path: str, body: object = None) -> tuple[int, object]:
        headers = {"Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            with self._opener.open(request, timeout=self.timeout) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as exc:
            status, raw = exc.code, exc.read()
        except (urllib.error.URLError, OSError) as exc:
            raise HubUnreachable(f"cannot reach the hub at {self.url} ({getattr(exc, 'reason', exc)})") from None
        try:
            return status, (json.loads(raw) if raw else None)
        except ValueError:
            return status, raw.decode("utf-8", "replace")[:200]

    def login(self, wait_s: float = 60.0) -> None:
        """Dev login; waits up to wait_s for a hub that is still starting."""
        deadline = time.monotonic() + wait_s
        while True:
            try:
                status, data = self.call("POST", "/api/v1/auth/token", {"username": self.user})
                break
            except HubUnreachable as exc:
                if time.monotonic() > deadline:
                    raise
                log("hub", f"{exc}; retrying")
                time.sleep(3)
        if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
            raise HubError(f"login as {self.user!r} failed (HTTP {status}: {detail(data)})")
        self.token = data["access_token"]


def _q(segment: str) -> str:
    return urllib.parse.quote(segment, safe="")


def _no_route(status: int, payload: object) -> bool:
    """FastAPI's answer for a path or method it does not have (an older hub without the admin API)."""
    return status == 405 or (status == 404 and detail(payload) == "Not Found")


def setup_hub(hub: Hub, building_id: str, rooms: list[Room], units: dict[str, dict]) -> list[Room]:
    """Give every room its zone in the hub, creating the missing ones (and the config's
    missing units). Sets room.hub_zone_id; returns the rooms that have a zone."""
    bid = _q(building_id)
    status, zones = hub.call("GET", f"/api/v1/buildings/{bid}/zones")
    if status != 200 or not isinstance(zones, list):
        raise HubError(f"cannot list the zones of building {building_id} (HTTP {status}: {detail(zones)})")
    by_id = {z.get("id") or z.get("zone_id"): z for z in zones}
    by_label = {(z.get("unit_id"), norm(z.get("label") or "")): z for z in zones}
    known_units = {z.get("unit_id") for z in zones}
    unit_map: dict[str, str] = {}             # config unit id -> hub unit id
    listing: list[dict] | None | bool = False  # admin unit listing: False = not loaded, None = no admin API

    def admin_units() -> list[dict] | None:
        nonlocal listing
        if listing is False:
            code, data = hub.call("GET", f"/api/v1/admin/buildings/{bid}/units")
            if code == 200 and isinstance(data, list):
                listing = [u for u in data if isinstance(u, dict)]
            elif _no_route(code, data):
                listing = None
            else:
                raise HubError(f"cannot list the units of {building_id} (HTTP {code}: {detail(data)})")
        return listing

    def hub_unit(unit_id: str) -> str:
        if unit_id in unit_map:
            return unit_map[unit_id]
        if unit_id in known_units:
            unit_map[unit_id] = unit_id
            return unit_id
        existing = admin_units()
        if existing is None:
            raise HubError("this hub has no admin API yet (update the backend), so its units cannot be checked")
        spec = units.get(unit_id)
        for u in existing:  # the unit itself, or one an earlier run created from the config
            uid = u.get("unit_id") or u.get("id")
            if uid == unit_id or (spec and norm(u.get("label") or "") == norm(spec["label"])
                                  and u.get("floor_id") == spec["floor_id"]):
                unit_map[unit_id] = uid
                return uid
        if spec is None:
            raise HubError(f"unit {unit_id} does not exist in the hub; use an existing one or describe it "
                           f"under \"units\" in the config")
        code, data = hub.call("POST", f"/api/v1/admin/buildings/{bid}/units", spec)
        if code not in (200, 201) or not isinstance(data, dict):
            raise HubError(f"creating unit {unit_id} failed (HTTP {code}: {detail(data)})")
        uid = data.get("unit_id") or data.get("id")
        log("hub", f"created unit {uid} '{spec['label']}' on {spec['floor_id']}")
        unit_map[unit_id] = uid
        return uid

    ready = []
    for room in rooms:
        try:
            zone = by_id.get(room.zone_id)
            if zone is None:
                unit = hub_unit(room.unit_id)
                zone = by_label.get((unit, norm(room.label)))  # created by an earlier run (the hub picks ids)
            if zone is None:
                body = {"label": room.label, "kind": room.kind, "unit_id": unit,
                        "pos_x": room.pos[0], "pos_y": room.pos[1]}
                code, data = hub.call("POST", f"/api/v1/admin/buildings/{bid}/zones", body)
                if _no_route(code, data):
                    raise HubError("this hub has no admin API yet (update the backend), so the zone cannot be created")
                if code not in (200, 201) or not isinstance(data, dict):
                    raise HubError(f"creating the zone failed (HTTP {code}: {detail(data)})")
                zone = data
                log("hub", f"created zone {data.get('zone_id') or data.get('id')} '{room.label}' "
                           f"({room.kind}, {unit}, at {room.pos[0]:g},{room.pos[1]:g} m)")
            room.hub_zone_id = zone.get("id") or zone.get("zone_id")
            ready.append(room)
        except HubError as exc:
            log("hub", f"room {room.short} skipped: {exc}")
    return ready


def place_nodes(hub: Hub, building_id: str, rooms: list[Room], stop: threading.Event,
                timeout_s: float = 90.0) -> None:
    """Wait until the hub registered every node, then move it into its room and name it."""
    wanted = {base: (room, kind) for room in rooms if room.hub_zone_id for kind, base in room.bases.items()}
    total, moved = len(wanted), 0
    deadline = time.monotonic() + timeout_s
    while wanted and not stop.is_set():
        try:
            code, nodes = hub.call("GET", f"/api/v1/buildings/{_q(building_id)}/nodes")
            listed = {n.get("mqtt_base"): n for n in nodes if isinstance(n, dict)} \
                if code == 200 and isinstance(nodes, list) else {}
            for base, (room, kind) in list(wanted.items()):
                node = listed.get(base)
                name = f"{room.label} · {NODE_NAMES[kind]}"
                if node and node.get("zone_id") == room.hub_zone_id and node.get("name") == name:
                    del wanted[base]  # already in place (an earlier run)
                    continue
                # Not listed: registered in another building, or not yet; its id is the slug of the base.
                node_id = node.get("id") if node else topic_slug(base)
                code, data = hub.call("PATCH", f"/api/v1/nodes/{_q(node_id)}",
                                      {"zone_id": room.hub_zone_id, "name": name})
                if code == 200:
                    log("hub", f"node {node_id} -> {room.hub_zone_id} '{name}'")
                    del wanted[base]
                    moved += 1
                elif code != 404:  # 404: not registered yet
                    log("hub", f"cannot move node {node_id} (HTTP {code}: {detail(data)})")
                    del wanted[base]
        except HubError as exc:
            log("hub", str(exc))
        if wanted and time.monotonic() > deadline:
            log("hub", f"gave up waiting for the hub to register {', '.join(sorted(wanted))}: "
                       f"is the backend connected to this broker?")
            return
        if wanted:
            stop.wait(2.0)
    if not wanted:
        log("hub", f"all {total} nodes are in their rooms ({moved} moved or renamed now)")


# ============================================================ MQTT pre-flight


def online_bases(args: argparse.Namespace, bases: list[str], settle_s: float = 0.7) -> list[str]:
    """Base topics whose retained availability is 'online': a running simulator (hw-sim) or a real
    sensor already uses them. Best effort: [] when the broker cannot be asked (start() says why)."""
    found: set[str] = set()
    subscribed = threading.Event()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"building-sim-check-{random.getrandbits(24):06x}",
                         protocol=mqtt.MQTTv311, clean_session=True)
    if args.username:
        client.username_pw_set(args.username, args.password)

    def on_connect(c, userdata, flags, reason_code, properties):
        if not reason_code.is_failure:
            c.subscribe([(f"{base}/availability", 0) for base in bases])

    def on_message(c, userdata, message):
        base = message.topic.rsplit("/", 1)[0]
        (found.add if bytes(message.payload) == b"online" else found.discard)(base)

    client.on_connect = on_connect
    client.on_subscribe = lambda *a: subscribed.set()
    client.on_message = on_message
    try:
        client.connect(args.host, args.port, keepalive=10)
    except (OSError, ValueError):
        return []
    client.loop_start()
    if subscribed.wait(5):
        time.sleep(settle_s)  # the broker sends the retained messages right after the SUBACK
    client.disconnect()
    client.loop_stop()
    return sorted(found)


# ============================================================ rooms and the building


def reset_environment(sim: Sim) -> None:
    """Clean air and a dry probe, so a new scenario starts from scratch (a leak latch stays,
    as on the device, until an OPEN command)."""
    air, water = sim.air, sim.water
    air.set_co(3)
    air.set_gas(640)
    air.set_smoke(0.0)
    air.presence = dict(hw_sim.PRESENCE_STILL)
    water.set_adc(312)


def room_script(sim: RoomSim, name: str, prelude: bool) -> Scenario:
    if name == "normal":
        yield from hw_sim.steady(sim)
        return
    if prelude:  # like hw_sim: finish the warm-up, let the hub see one normal heartbeat
        if sim.air in sim.nodes:
            yield from sim.wait_until(lambda: not sim.air.warming_up(sim.clock.now()))
        yield from sim.wait(AirNode.heartbeat_s)
    sim.say(f"scenario {name}")
    yield from hw_sim.SCENARIOS[name](sim)


class RoomSim(Sim):
    """One room: hw_sim's Sim on the building's shared clock (its scenarios drive self.air and
    self.water), with only the room's own nodes connected."""

    def __init__(self, room: Room, clock: Clock, args: argparse.Namespace) -> None:
        node_args = argparse.Namespace(**vars(args))
        node_args.air_base = room.bases.get("air", f"air-{topic_slug(room.short)}")
        node_args.water_base = room.bases.get("water", f"water-{topic_slug(room.short)}")
        node_args.verbose = False  # no raw documents on the console
        super().__init__(node_args, clock)
        self.room = room
        self.nodes = [{"air": self.air, "water": self.water}[kind] for kind in room.nodes]
        for node in self.nodes:
            node.log_heartbeats = args.verbose
        self.scenario = room.scenario
        self.steps: Scenario | None = None
        self.started = False

    def say(self, text: str) -> None:
        log(self.room.short, text)

    def start(self) -> None:
        now = self.clock.now()
        for node in (self.air, self.water):
            if node not in self.nodes:
                node.boot(now)  # never connected; booted so the scenarios can drive it harmlessly
        super().start()      # boot, settle and connect the room's nodes (hw_sim)
        self.started = True
        self.steps = room_script(self, self.scenario, prelude=True)

    def play(self, name: str) -> str:
        """Switch to a scenario now (no warm-up wait)."""
        reset_environment(self)
        if self.started:
            for node in self.nodes:  # a scenario cut short (offline, reboot) may have left one off
                if node.client is None:
                    node.connect()
        self.scenario = name
        self.steps = room_script(self, name, prelude=False)
        text = f"{self.room.short}: {name}"
        if "water" in self.room.nodes and self.water.leak_latched and name != "leak":
            text += f" (leak still latched, valve closed: type '{self.room.short} deschide' or press OPEN)"
        return text

    def tick(self) -> None:
        if self.steps is not None:
            try:
                next(self.steps)
            except StopIteration:
                self.say(f"{self.scenario} finished; back to normal")
                self.scenario = "normal"
                self.steps = room_script(self, "normal", prelude=False)
        now = self.clock.now()
        for node in self.nodes:
            node.service(now)

    def state(self) -> str:
        now, parts = self.clock.now(), []
        if self.air in self.nodes:
            air = self.air
            alarm = air.alarm_state + (f"/{air.alarm_hazard}" if air.alarm_hazard != "none" else "")
            parts.append(f"air {alarm if air.connected else 'offline'}"
                         f"{' (warm-up)' if air.warming_up(now) else ''}")
        if self.water in self.nodes:
            water = self.water
            parts.append(f"water {water.sensor_state}{' latched' if water.leak_latched else ''}, "
                         f"valve {water.valve}, alarm {water.alarm_state(now)}" if water.connected else "water offline")
        return " | ".join(parts)


class Building:
    def __init__(self, rooms: list[Room], args: argparse.Namespace) -> None:
        self.clock = Clock(5.0 if args.fast else 1.0)
        self.sims = [RoomSim(room, self.clock, args) for room in rooms]
        self.lock = threading.Lock()   # the main loop, the console and the HTTP control take turns
        self.stop_event = threading.Event()

    def start(self) -> None:
        for sim in self.sims:
            sim.start()

    def stop(self, quiet: bool = False) -> None:
        for sim in self.sims:
            sim.stop(quiet=True)
        if not quiet:
            log("building", f"stopped: {sum(len(s.nodes) for s in self.sims)} connections dropped, "
                            f"the broker publishes each node's will (offline)")

    def run(self, duration: float = 0.0) -> None:
        while not self.stop_event.is_set():
            with self.lock:
                for sim in self.sims:
                    sim.tick()
            if duration and self.clock.real() >= duration:
                return
            time.sleep(hw_sim.TICK_S)

    def find(self, query: str) -> list[RoomSim]:
        rooms = match_rooms([s.room for s in self.sims], query)
        return [s for s in self.sims if s.room in rooms]

    def command(self, target: str, word: str) -> tuple[bool, str]:
        """<room> <scenario or firmware command>; returns (ok, answer)."""
        try:
            sims = self.find(target)
        except LookupError as exc:
            return False, str(exc)
        key = norm(word)
        action = ACTION_ALIASES.get(key, key)
        if action in ACTIONS:
            return self._act(sims, action)
        try:
            name = scenario_name(word)
        except ConfigError as exc:
            return False, f"{exc}; or a command: {', '.join(ACTIONS)} ({', '.join(ACTION_ALIASES)})"
        done, skipped = [], []
        for sim in sims:
            (skipped if missing_nodes(name, sim.room.nodes) else done).append(sim)
        if not done:
            return False, f"{name} needs a {'+'.join(sorted(SCENARIO_NEEDS[name]))} node; " \
                          f"{', '.join(s.room.short for s in skipped)} has none"
        lines = [sim.play(name) for sim in done]
        if skipped:
            lines.append(f"skipped (no {'+'.join(sorted(SCENARIO_NEEDS[name]))} node): "
                         f"{', '.join(s.room.short for s in skipped)}")
        return True, "\n".join(lines)

    def _act(self, sims: list[RoomSim], action: str) -> tuple[bool, str]:
        sent, problems = 0, []
        for sim in sims:
            for kind, suffix, payload in ACTIONS[action]:
                if kind not in sim.room.nodes:
                    continue
                node = sim.air if kind == "air" else sim.water
                if node.client is None or not node.connected:
                    problems.append(f"{sim.room.short}: {kind} node offline")
                    continue
                sim.send_command(node, suffix, payload)  # the node answers on <base>/command/result
                sent += 1
        if not sent and not problems:
            kinds = "+".join(sorted({kind for kind, _, _ in ACTIONS[action]}))
            problems.append(f"{action} needs a {kinds} node; {', '.join(s.room.short for s in sims)} has none")
        return sent > 0, "\n".join(problems)

    def execute(self, line: str) -> str:
        """One console line; returns the text to print."""
        words = line.split()
        if not words:
            return ""
        if len(words) == 1:
            word = norm(words[0])
            if word in ("list", "lista", "ls", "status"):
                return self.listing()
            if word in ("help", "ajutor", "h") or words[0] == "?":
                return HELP
            if word in ("quit", "exit", "q", "iesire", "stop"):
                self.stop_event.set()
                return "stopping..."
            return f"{line!r}? type <room> <scenario>, or help"
        return self.command(" ".join(words[:-1]), words[-1])[1]

    def listing(self) -> str:
        table = [("room", "label", "unit", "scenario", "state")]
        table += [(s.room.short, s.room.label, s.room.unit_label or s.room.unit_id, s.scenario, s.state()) for s in self.sims]
        widths = [max(len(row[i]) for row in table) for i in range(4)]
        return "\n".join("  " + " ".join(cell.ljust(w) for cell, w in zip(row, widths)) + " " + row[4]
                         for row in table)

    def rooms_json(self) -> list[dict]:
        return [{"zone_id": s.room.zone_id, "hub_zone_id": s.room.hub_zone_id, "label": s.room.label,
                 "unit_id": s.room.unit_id, "kind": s.room.kind, "nodes": s.room.bases,
                 "scenario": s.scenario, "state": s.state()} for s in self.sims]


def read_console(building: Building) -> None:
    with_errors = getattr(sys.stdin, "reconfigure", None)
    if with_errors:
        try:
            with_errors(errors="replace")
        except (ValueError, OSError):
            pass
    for line in iter(sys.stdin.readline, ""):  # ends quietly on EOF (no terminal attached)
        if line.strip():
            with building.lock:
                answer = building.execute(line.strip())
            if answer:
                print(answer, flush=True)
        if building.stop_event.is_set():
            return


def serve_control(building: Building, port: int) -> ThreadingHTTPServer:
    """GET /rooms, POST /rooms/<room>/scenario?name=<scenario>, on 127.0.0.1 only."""

    class Handler(BaseHTTPRequestHandler):
        def _send(self, code: int, payload: object) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802 - http.server API
            if urllib.parse.urlsplit(self.path).path.rstrip("/") == "/rooms":
                with building.lock:
                    rooms = building.rooms_json()
                self._send(200, rooms)
            else:
                self._send(404, {"error": "GET /rooms or POST /rooms/<room>/scenario?name=<scenario>"})

        def do_POST(self) -> None:  # noqa: N802 - http.server API
            parts = urllib.parse.urlsplit(self.path)
            segments = [urllib.parse.unquote(s) for s in parts.path.strip("/").split("/")]
            name = urllib.parse.parse_qs(parts.query).get("name", [""])[0]
            if len(segments) != 3 or segments[0] != "rooms" or segments[2] != "scenario" or not name:
                self._send(404, {"error": "POST /rooms/<room>/scenario?name=<scenario>"})
                return
            with building.lock:
                ok, text = building.command(segments[1], name)
            self._send(200 if ok else 400, {"ok": ok, "message": text})

        def log_message(self, *args) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# ============================================================ main


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Many simulated Canary rooms (firmware-accurate air/water nodes) in one process.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="config: {\"building_id\": \"bld_007\", \"rooms\": [{\"zone_id\": \"zone_kitchen\", "
               "\"label\": \"Bucătărie\",\n  \"unit_id\": \"unit_0312\", \"kind\": \"kitchen\", \"pos\": [2, 2], "
               "\"nodes\": [\"air\", \"water\"], \"scenario\": \"normal\"}]}\n"
               f"  kind: {', '.join(ZONE_KINDS)}; optional per room: air_base, water_base\n"
               f"scenarios: {', '.join(SCENARIO_NEEDS)} (see hw_sim.py --help); "
               f"Romanian: {', '.join(SCENARIO_ALIASES)}\n\n" + HELP)
    p.add_argument("--config", default="rooms.demo.json", help="rooms JSON (default rooms.demo.json)")
    p.add_argument("--scenario", action="append", default=[], metavar="ROOM=SCENARIO",
                   help="override a room's scenario, e.g. kitchen=gas or bucatarie=gaz; all=SCENARIO "
                        "or a bare SCENARIO for every room (repeatable)")
    p.add_argument("--base-prefix", default=os.environ.get("BASE_PREFIX", ""), metavar="PREFIX",
                   help="prepended to every node base topic, e.g. demo- (env BASE_PREFIX; default none)")
    p.add_argument("--no-console", action="store_true",
                   help="do not read stdin; run until SIGTERM, Ctrl-C or --duration")
    p.add_argument("--only", default="", metavar="ROOM,ROOM", help="simulate only these rooms")
    p.add_argument("--hub", default=os.environ.get("HUB_URL") or "http://localhost:8000",
                   help="hub REST API (env HUB_URL, default http://localhost:8000)")
    p.add_argument("--hub-user", default=os.environ.get("HUB_USER") or "admin",
                   help="dev login used for the API (env HUB_USER, default admin)")
    p.add_argument("--no-hub", action="store_true", help="MQTT only: do not create zones or move nodes")
    p.add_argument("--host", default=os.environ.get("MQTT_HOST", "localhost"),
                   help="broker host (env MQTT_HOST, default localhost)")
    p.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")),
                   help="broker port (env MQTT_PORT, default 1883)")
    p.add_argument("--username", default=os.environ.get("MQTT_USERNAME") or None,
                   help="broker user (env MQTT_USERNAME)")
    p.add_argument("--password", default=os.environ.get("MQTT_PASSWORD") or None,
                   help="broker password (prefer env MQTT_PASSWORD: arguments are visible to other local users)")
    p.add_argument("--fast", action="store_true", help="firmware timers, heartbeats and scenarios 5x faster")
    p.add_argument("--warmup", type=float, default=20.0,
                   help="air sensor warm-up after boot, seconds (firmware default 300; 0 = none; default 20)")
    p.add_argument("--duration", type=float, default=0.0,
                   help="stop after this many real seconds (default 0 = until quit / Ctrl-C)")
    p.add_argument("--control-port", type=int, default=0, metavar="PORT",
                   help="also take commands over HTTP on 127.0.0.1:PORT (GET /rooms, "
                        "POST /rooms/<room>/scenario?name=gas); default off")
    p.add_argument("--force", action="store_true",
                   help="start even if a base topic is already online on the broker (another simulator?)")
    p.add_argument("-v", "--verbose", action="store_true", help="also log every heartbeat")
    args = p.parse_args(argv)
    if args.warmup < 0:
        p.error("--warmup must be >= 0")
    if not 0 <= args.control_port <= 65535:
        p.error("--control-port must be 0-65535")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        cfg = load_config(args.config)
        rooms = select_rooms(cfg.rooms, args.only) if args.only else cfg.rooms
        overrides = parse_overrides(args.scenario, rooms)
        for room in rooms:
            room.scenario = overrides.get(room.zone_id, room.scenario)
        apply_base_prefix(rooms, args.base_prefix)
    except ConfigError as exc:
        print(f"building_sim: {exc}", file=sys.stderr)
        return 2

    def on_sigterm(signum, frame):  # docker stop -> clean shutdown path
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_sigterm)
    bases = [base for room in rooms for base in room.bases.values()]
    log("building", f"{cfg.building_id}: {len(rooms)} rooms, {len(bases)} nodes; broker {args.host}:{args.port} "
                    f"as {args.username or '(anonymous)'}; hub {'off' if args.no_hub else args.hub}"
                    f"{'; fast x5' if args.fast else ''}")
    if not args.force:
        busy = online_bases(args, bases)
        if busy:
            log("building", f"error: already online on the broker: {', '.join(busy)}. Another simulator "
                            f"(hw-sim, an earlier building-sim) or a real sensor uses these base topics: "
                            f"stop it first (or --force)")
            return 1
    hub = None
    if not args.no_hub:
        try:
            hub = Hub(args.hub, args.hub_user)
            hub.login()
            rooms = setup_hub(hub, cfg.building_id, rooms, cfg.units)
        except HubError as exc:
            log("hub", f"error: {exc} (--hub URL, or --no-hub to run the nodes without the API)")
            return 1
        if not rooms:
            log("building", "error: no room left to simulate")
            return 1
    building = Building(rooms, args)
    try:
        if args.control_port:
            serve_control(building, args.control_port)
            log("building", f"HTTP control on http://127.0.0.1:{args.control_port}/rooms")
        building.start()
        if hub is not None:
            threading.Thread(target=place_nodes, args=(hub, cfg.building_id, rooms, building.stop_event),
                             daemon=True).start()
        print(building.listing(), flush=True)
        if args.no_console:
            log("building", "running; no console (stop with SIGTERM)")
        else:
            log("building", "running; type e.g. 'bucatarie gaz', 'toate normal', 'list', 'help' or 'quit'")
            threading.Thread(target=read_console, args=(building,), daemon=True).start()
        building.run(args.duration)
    except ConnectError as exc:
        log("building", f"error: {exc}")
        building.stop(quiet=True)
        return 1
    except OSError as exc:  # e.g. the control port is taken
        log("building", f"error: {exc}")
        building.stop(quiet=True)
        return 1
    except KeyboardInterrupt:
        pass
    building.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
