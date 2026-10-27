"""Water-leak impact map: the units a leak may reach, from an explicit plumbing topology.

The topology is a JSON file (CANARY_WATER_TOPOLOGY_FILE, docs/WATER_TOPOLOGY.md) written by whoever
knows the building: per building, which units sit directly below each unit, and which units share a
riser. Nothing is inferred from floor numbers or positions. A leak's units are those of its incident
zones. The result lists:

- `below`: units under a leaking unit, following "directly below" down to MAX_HOPS floors;
- `riser`: other units on a riser a leaking unit shares (the leak may be in the shared pipe).

"Potentially affected" only: there is no volume or spread estimate, and nothing here closes a valve
or changes an incident.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("canary.water")

MAX_HOPS = 6
NOT_CONFIGURED, INVALID, CONFIGURED = "not_configured", "invalid", "configured"


@dataclass(frozen=True)
class BuildingTopology:
    below: dict[str, list[str]] = field(default_factory=dict)
    risers: dict[str, list[str]] = field(default_factory=dict)


@dataclass(frozen=True)
class Impact:
    unit_id: str
    reason: str  # below | riser
    hops: int | None  # floors under the leak (below), None for riser
    via_unit_id: str  # the leaking unit it is reached from
    riser: str | None = None


def _str_list_map(value: object) -> dict[str, list[str]] | None:
    if not isinstance(value, dict):
        return None
    out = {}
    for key, units in value.items():
        if not isinstance(key, str) or not isinstance(units, list) or not all(isinstance(u, str) for u in units):
            return None
        out[key] = list(dict.fromkeys(units))
    return out


def parse_topology(doc: object) -> dict[str, BuildingTopology] | None:
    """`{"buildings": {id: {"below": {unit: [units]}, "risers": {riser: [units]}}}}`; None if malformed."""
    buildings = doc.get("buildings") if isinstance(doc, dict) else None
    if not isinstance(buildings, dict):
        return None
    out = {}
    for building_id, spec in buildings.items():
        if not isinstance(spec, dict):
            return None
        below, risers = _str_list_map(spec.get("below", {})), _str_list_map(spec.get("risers", {}))
        if below is None or risers is None:
            return None
        out[building_id] = BuildingTopology(below=below, risers=risers)
    return out


def load_topology(path: str) -> tuple[str, dict[str, BuildingTopology]]:
    """(status, topology). Read on every call: a small file, and an edit applies without a restart."""
    if not path:
        return NOT_CONFIGURED, {}
    try:
        topology = parse_topology(json.loads(Path(path).read_text(encoding="utf-8")))
    except (OSError, ValueError) as exc:
        log.warning("water topology %s unreadable: %s", path, exc)
        return INVALID, {}
    if topology is None:
        log.warning("water topology %s is malformed (docs/WATER_TOPOLOGY.md)", path)
        return INVALID, {}
    return CONFIGURED, topology


def affected_units(topology: BuildingTopology, leaking: set[str]) -> list[Impact]:
    """Units potentially reached from the leaking units: below first (nearest floor first), then
    riser neighbours. Leaking units themselves are not listed."""
    found: dict[str, Impact] = {}
    frontier = [(u, u) for u in sorted(leaking)]
    for hops in range(1, MAX_HOPS + 1):
        nxt = []
        for unit, origin in frontier:
            for under in topology.below.get(unit, []):
                if under in leaking or under in found:
                    continue
                found[under] = Impact(unit_id=under, reason="below", hops=hops, via_unit_id=origin)
                nxt.append((under, origin))
        frontier = nxt
    for riser, units in sorted(topology.risers.items()):
        for origin in sorted(leaking & set(units)):
            for unit in units:
                if unit in leaking:
                    continue
                if unit in found:
                    if found[unit].riser is None:
                        old = found[unit]
                        found[unit] = Impact(old.unit_id, old.reason, old.hops, old.via_unit_id, riser)
                    continue
                found[unit] = Impact(unit_id=unit, reason="riser", hops=None, via_unit_id=origin, riser=riser)
    return sorted(found.values(), key=lambda i: (i.reason != "below", i.hops or 0, i.unit_id))
