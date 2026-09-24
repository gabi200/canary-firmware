"""Pure state-machine tests (no DB / no third-party deps required to reason about logic)."""

from __future__ import annotations

from app.enums import IncidentState as S
from app.incidents.state_machine import can_transition, closing_state, forward_chain


def test_legal_and_illegal_transitions():
    assert can_transition(S.normal, S.detection)
    assert can_transition(S.detection, S.alarm)  # fast path
    assert can_transition(S.alarm, S.evacuation)
    assert can_transition(S.alarm, S.escalation)
    # forward-only safety: no silent regression out of an active alarm
    assert not can_transition(S.alarm, S.detection)
    assert not can_transition(S.evacuation, S.alarm)
    assert not can_transition(S.normal, S.alarm)  # must pass through detection


def test_forward_chain_first_detection():
    assert forward_chain(S.normal, S.detection, fast_path=False, escalation_warranted=False) == [S.detection]


def test_forward_chain_verification_step():
    assert forward_chain(S.detection, S.verification, fast_path=False, escalation_warranted=False) == [
        S.verification
    ]


def test_forward_chain_critical_fast_path_to_evacuation():
    # critical gas/CO from a fresh incident: open(detection) -> alarm -> escalation -> evacuation,
    # skipping verification (fast path), including escalation (warranted).
    chain = forward_chain(S.normal, S.evacuation, fast_path=True, escalation_warranted=True)
    assert chain == [S.detection, S.alarm, S.escalation, S.evacuation]
    assert S.verification not in chain


def test_forward_chain_skips_escalation_when_not_warranted():
    chain = forward_chain(S.normal, S.evacuation, fast_path=True, escalation_warranted=False)
    assert chain == [S.detection, S.alarm, S.evacuation]


def test_forward_chain_no_backward():
    assert forward_chain(S.evacuation, S.alarm, fast_path=True, escalation_warranted=False) == []


def test_closing_state():
    assert closing_state(S.detection) == S.false_alarm
    assert closing_state(S.verification) == S.false_alarm
    assert closing_state(S.alarm) == S.resolution
    assert closing_state(S.evacuation) == S.resolution
