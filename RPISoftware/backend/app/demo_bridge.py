"""Demo incidents sound the real nodes: the first time an incident in the Demo building reaches an
alarmed state while the hub is in Demo mode, every online node of the Real building gets a buzzer
TEST (air) or a valve CLOSE (water), so a presentation feels real. In Real mode a stray Demo
building incident must not close the real valve, so nothing is sent.

`commands.send` publishes and commits, so it cannot run in the incident's transaction. The decision
is taken inside the transition (`queue`) and the commands go out after that transaction commits
(never on rollback), from a background task with its own session, like app.notify.escalation. The
incident path neither waits for them nor sees their failures.
"""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy import event, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import commands
from app.config import settings
from app.db import SessionLocal
from app.enums import ALARMED_STATES, IncidentState
from app.mode import get_mode
from app.models import DeviceCommand, Incident, Node

log = logging.getLogger("canary.demo_bridge")

ACTOR = "system:demo"  # not a user row: command lists show it without a requester name
_COMMAND_FOR_KIND = {"air": "TEST", "water": "CLOSE"}

_PENDING = "canary_demo_mirrors"  # session.info key: mirrors waiting for the commit
_HOOKED = "canary_demo_mirror_hooks"
_tasks: set[asyncio.Task] = set()


def should_mirror(incident: Incident, from_state: IncidentState, to_state: IncidentState) -> bool:
    """A critical reading chains through several alarmed states; only the first entry counts.
    A closed incident never reopens (the next reading opens a new one), so this is once per incident."""
    return (
        incident.building_id == settings.demo_building_id
        and to_state in ALARMED_STATES
        and from_state not in ALARMED_STATES
    )


async def _online_live_node_ids(session: AsyncSession) -> list[str]:
    rows = await session.scalars(
        select(Node.id).where(Node.building_id == settings.live_building_id, Node.online.is_(True)).order_by(Node.id)
    )
    return list(rows.all())


async def mirror(
    session: AsyncSession, incident: Incident, from_state: IncidentState, to_state: IncidentState
) -> list[DeviceCommand]:
    """Command the real nodes and return the commands sent, only in Demo mode (read here, at send
    time; a failed read sends nothing). Commits `session`, so never pass the incident's own. A
    failing node is logged and the next one still gets its command. Never raises."""
    sent: list[DeviceCommand] = []
    try:
        if not should_mirror(incident, from_state, to_state):
            return sent
        if await get_mode(session) != "demo":
            log.info("demo mirror skipped for incident %s: hub is not in demo mode", incident.id)
            return sent
        for node_id in await _online_live_node_ids(session):
            try:
                node = await session.get(Node, node_id)  # read per node: a rollback below expires loaded rows
                command = _COMMAND_FOR_KIND.get(node.kind) if node is not None else None
                if command is None or await commands.too_soon(session, node_id):
                    continue
                sent.append(await commands.send(session, node, command, ACTOR))
            except Exception:  # noqa: BLE001
                log.exception("demo mirror failed for node %s", node_id)
                await session.rollback()
    except Exception:  # noqa: BLE001
        log.exception("demo mirror failed")
    return sent


async def _run(incident_id: str, from_state: IncidentState, to_state: IncidentState) -> None:
    try:
        async with SessionLocal() as session:
            incident = await session.get(Incident, incident_id)
            if incident is not None:
                await mirror(session, incident, from_state, to_state)
    except Exception:  # noqa: BLE001
        log.exception("demo mirror for incident %s failed", incident_id)


def queue(session: AsyncSession, incident: Incident, from_state: IncidentState, to_state: IncidentState) -> None:
    """Called in the transition: remember the mirror until the caller's transaction commits. Never raises."""
    try:
        if not should_mirror(incident, from_state, to_state):
            return
        sync = session.sync_session
        sync.info.setdefault(_PENDING, []).append((incident.id, from_state, to_state))
        if not sync.info.get(_HOOKED):
            sync.info[_HOOKED] = True
            event.listen(sync, "after_commit", _after_commit)
            event.listen(sync, "after_rollback", _after_rollback)
    except Exception:  # noqa: BLE001 - the incident pipeline must not depend on the demo
        log.exception("queueing the demo mirror failed")


def _after_commit(sync_session) -> None:
    try:
        # Also runs on a savepoint release (the signature classifier uses one), which commits nothing yet.
        if sync_session.in_nested_transaction():
            return
        for args in sync_session.info.pop(_PENDING, []):
            task = asyncio.get_running_loop().create_task(_run(*args), name=f"demo-mirror:{args[0]}")
            _tasks.add(task)
            task.add_done_callback(_tasks.discard)
    except Exception:  # noqa: BLE001 - raising here would surface from the incident's session.commit()
        log.exception("starting the demo mirror failed")


def _after_rollback(sync_session) -> None:
    if not sync_session.in_nested_transaction():
        sync_session.info.pop(_PENDING, None)


async def drain() -> None:
    """Wait for every in-flight mirror (tests)."""
    while _tasks:
        await asyncio.gather(*list(_tasks), return_exceptions=True)
