"""Incident state machine (pure, ARCHITECTURE.md section 7).

Forward-only into alarm/escalation/evacuation for safety: no silent regression out
of an active alarm except via an explicit resolution/false_alarm transition with a
logged actor. Pure stdlib so it is unit-testable with no dependencies installed.
"""

from __future__ import annotations

from app.enums import IncidentState as S

# Allowed transitions. Note the deliberate fast-path edges (detection -> alarm,
# detection/verification -> false_alarm, alarm -> evacuation skipping escalation).
ALLOWED: dict[S, frozenset[S]] = {
    S.normal: frozenset({S.detection}),
    S.detection: frozenset({S.verification, S.alarm, S.evacuation, S.false_alarm, S.resolution}),
    S.verification: frozenset({S.alarm, S.evacuation, S.false_alarm, S.resolution}),
    S.alarm: frozenset({S.escalation, S.evacuation, S.resolution, S.false_alarm}),
    S.escalation: frozenset({S.evacuation, S.resolution}),
    S.evacuation: frozenset({S.resolution}),
    S.resolution: frozenset({S.normal}),
    S.false_alarm: frozenset({S.normal}),
}

# Monotonic rank along the escalation axis. resolution/false_alarm are terminal
# (closing) states and sit off this axis (rank -1).
_RANK: dict[S, int] = {
    S.normal: 0,
    S.detection: 1,
    S.verification: 2,
    S.alarm: 3,
    S.escalation: 4,
    S.evacuation: 5,
    S.resolution: -1,
    S.false_alarm: -1,
}

# Optional stages that can be skipped when not warranted.
_OPTIONAL = {S.verification, S.escalation}

# The escalation axis in order.
_AXIS: list[S] = [S.detection, S.verification, S.alarm, S.escalation, S.evacuation]


def can_transition(src: S, dst: S) -> bool:
    return dst in ALLOWED.get(src, frozenset())


def rank(state: S) -> int:
    return _RANK[state]


def forward_chain(current: S, target: S, *, fast_path: bool, escalation_warranted: bool) -> list[S]:
    """Return the ordered list of states to traverse from `current` up to `target`.

    Skips `verification` when `fast_path` is set, and skips `escalation` unless
    `escalation_warranted`. Returns [] when target is not strictly ahead of current
    on the escalation axis (clearing/closing is handled separately).
    """
    if target is None:
        return []
    start = rank(current)
    end = rank(target)
    if end <= start:
        return []

    chain: list[S] = []
    for state in _AXIS:
        r = rank(state)
        if r <= start or r > end:
            continue
        if state == S.verification and fast_path:
            continue
        if state == S.escalation and not escalation_warranted:
            continue
        chain.append(state)
    # Guarantee the target is the final state even if it was filtered as optional.
    if not chain or chain[-1] != target:
        if target not in chain:
            chain.append(target)
    return chain


def closing_state(current: S) -> S:
    """When readings clear: incidents that never alarmed close as false_alarm; alarmed close as resolution."""
    if current in (S.detection, S.verification):
        return S.false_alarm
    return S.resolution
