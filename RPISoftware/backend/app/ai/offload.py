"""AI tasks: computed on the AI node of a three-Pi hub, or here (RUNME.md section 3).

The tasks estimate and never decide: hazard-source triangulation (a weighted centroid), the
signature shadow model (stored and logged; no decision reads it) and the incident brief. Detection,
the state machine, the false-alarm classifier and the signature rules stay with the caller.

compute() sends a task to cluster.ai_peer() and runs it here instead when there is no peer (single
mode, or this node is the AI target) or the peer fails: down, refused, slower than the timeout (0.25 s
on the safety path) or a malformed answer. Work is never lost, and after a failure the peer is
skipped for BREAKER_S, so an AI node that is down costs one timeout, not one per reading.

Results travel as JSON and rebuild exactly the objects a local call returns: dataclasses.asdict on
one side, the constructors on the other, and json writes floats with repr, which round-trips.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import asdict
from time import monotonic

from app import cluster
from app.ai import brief
from app.analytics import triangulation
from app.analytics.signature import model as signature_model
from app.analytics.signature.features import SignatureFeatures

log = logging.getLogger("canary.ai")

TIMEOUT_S = 0.25  # the safety path's tasks: microseconds of work, and the fallback here gives the same
# answer, so a slow AI node may only cost the alarm path this much (once per BREAKER_S)
BRIEF_TIMEOUT_S = 90.0  # the AI node's LLM gives up after llm.CHAT_TIMEOUT_S and sends its template
BREAKER_S = 15.0  # after a failure the AI node is not asked for this long

_skip_until = 0.0  # monotonic() before which compute() does not ask the AI node
_failing = False  # the current outage is logged already


# --------------------------------------------------------------------------- #
# JSON round trip: the rebuilders raise on a malformed answer
# --------------------------------------------------------------------------- #
def triangulation_payload(sensors: list[triangulation.SensorPoint], zones: dict[str, tuple[float, float]]) -> dict:
    return {"sensors": [asdict(s) for s in sensors], "zones": {zone: list(xy) for zone, xy in zones.items()}}


def triangulation_result(data: dict) -> triangulation.TriangulationResult:
    contributors = [triangulation.Contributor(**c) for c in data["contributors"]]
    return triangulation.TriangulationResult(**{**data, "contributors": contributors})


def shadow_result(data: dict) -> signature_model.ShadowPrediction | None:
    return signature_model.ShadowPrediction(**data) if data else None  # {}: no shadow model


def brief_result(data: dict) -> dict:
    """{"text", "source": "llm" | "template", "model", "node"} as the writing node answered it."""
    if not (isinstance(data.get("text"), str) and data["text"] and data.get("source") in ("llm", "template")
            and isinstance(data.get("node"), str) and isinstance(data.get("model"), str | None)):
        raise ValueError("malformed brief")
    return data


# --------------------------------------------------------------------------- #
# Tasks
# --------------------------------------------------------------------------- #
async def _triangulate(payload: dict) -> dict:
    sensors = [triangulation.SensorPoint(**s) for s in payload["sensors"]]
    zones = {zone: tuple(xy) for zone, xy in payload["zones"].items()}
    return asdict(triangulation.triangulate(sensors, zones))


async def _signature_shadow(payload: dict) -> dict:
    prediction = signature_model.predict(SignatureFeatures(**payload))
    return asdict(prediction) if prediction is not None else {}


async def _brief(payload: dict) -> dict:
    return await brief.generate(payload["facts"], payload["lang"])


# task -> (compute it here, rebuild its result)
_TASKS: dict[str, tuple[Callable[[dict], Awaitable[dict]], Callable[[dict], object]]] = {
    "triangulate": (_triangulate, triangulation_result),
    "signature_shadow": (_signature_shadow, shadow_result),
    "brief": (_brief, brief_result),
}


async def run_local(task: str, payload: dict) -> dict:
    """Compute `task` on this node (POST /internal/ai/{task} runs this for the other nodes); the
    result is JSON-able. KeyError: unknown task, and only then (a payload missing a field is a
    ValueError)."""
    run = _TASKS[task][0]
    try:
        return await run(payload)
    except KeyError as exc:
        raise ValueError(f"{task} payload lacks {exc}") from exc


async def compute(task: str, payload: dict, timeout: float = TIMEOUT_S) -> dict:
    """`task` on the AI node when there is one and it answers well within `timeout`, else here."""
    global _skip_until, _failing
    rebuild = _TASKS[task][1]  # KeyError: unknown task, before asking anyone
    base = cluster.ai_peer()
    if base is not None and monotonic() >= _skip_until:
        try:
            result = await cluster.call_peer(base, f"/internal/ai/{task}", payload, timeout)
            if not isinstance(result, dict):
                raise TypeError(f"answer is {type(result).__name__}, not an object")
            rebuild(result)  # a malformed answer (say, from a node on another version) is a failure too
        except Exception as exc:  # noqa: BLE001 - whatever went wrong there, the work is done here
            _skip_until = monotonic() + BREAKER_S
            if not _failing:
                _failing = True
                log.warning("AI node %s failed (%s: %r); computing here, asking it again in %.0f s",
                            base, task, exc, BREAKER_S)
        else:
            if _failing:
                _failing = False
                log.info("AI node %s answers again", base)
            return result
    return await run_local(task, payload)


# --------------------------------------------------------------------------- #
# Typed calls for the callers
# --------------------------------------------------------------------------- #
async def triangulate(
    sensors: list[triangulation.SensorPoint], zones: dict[str, tuple[float, float]]
) -> triangulation.TriangulationResult:
    """triangulation.triangulate(sensors, zones), wherever compute() runs it."""
    return triangulation_result(await compute("triangulate", triangulation_payload(sensors, zones)))


async def signature_shadow(features: SignatureFeatures) -> signature_model.ShadowPrediction | None:
    """The shadow model's prediction (signature_model.predict), wherever compute() runs it."""
    return shadow_result(await compute("signature_shadow", asdict(features)))


async def write_brief(facts: dict, lang: str) -> dict:
    """The incident brief (app.ai.brief.generate) by the AI node's LLM, or this node's LLM or template."""
    return await compute("brief", {"facts": facts, "lang": lang}, BRIEF_TIMEOUT_S)
