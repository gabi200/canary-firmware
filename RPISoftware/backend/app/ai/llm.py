"""The incident brief's LLM: a Raspberry Pi AI HAT+ 2 (Hailo-10H) serving a small model through
hailo-ollama, an Ollama-compatible API on this Pi (CANARY_LLM_URL, CANARY_LLM_MODEL).

Local to the hub by design: there is no cloud model, so incident facts never leave the building's
network. run_probe() asks GET /api/tags every PROBE_INTERVAL_S whether the server answers and lists
the model; accelerator_status() reports that (GET /api/v1/cluster) and chat() does not wait on a
server the probe found offline. chat() answers None on any failure: callers fall back to a template.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import urllib.request

from app.config import settings

log = logging.getLogger("canary.ai")

PROBE_INTERVAL_S = 30.0
PROBE_TIMEOUT_S = 2.0
CHAT_TIMEOUT_S = 60.0  # a 1.5B model on the HAT writes a brief in well under this

_online: bool | None = None  # what the last probe found; None: not probed yet
_slot = asyncio.Semaphore(1)  # the HAT writes one answer at a time; queued briefs must not each hold a thread
_THINK = re.compile(r"<think>.*?</think>", re.S)  # a reasoning model's scratchpad, never shown


def accelerator_status() -> dict | None:
    """This node's LLM as GET /api/v1/cluster shows it; None without CANARY_LLM_URL."""
    if not settings.llm_url:
        return None
    return {"kind": "hailo-ollama", "online": bool(_online), "model": settings.llm_model}


def _request(url: str, body: bytes | None, timeout: float) -> bytes:
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - hailo-ollama on this Pi
        return response.read()


async def _call(path: str, body: bytes | None, timeout: float) -> bytes:
    """GET (no body) or POST to hailo-ollama off the event loop; raises on failure or timeout."""
    url = settings.llm_url.rstrip("/") + path
    return await asyncio.wait_for(asyncio.to_thread(_request, url, body, timeout), timeout + 0.5)


def _model_key(name: str) -> str:
    return name.strip().lower().removesuffix(":latest")  # Ollama: "m" and "m:latest" are one model


def _listed(tags: object, model: str) -> bool:
    """Whether an /api/tags answer lists `model`. Ollama answers {"models": [{"name": ...}]};
    a bare list, plain strings or a `model` key are accepted too."""
    entries = tags.get("models") if isinstance(tags, dict) else tags
    names: list[object] = []
    for entry in entries if isinstance(entries, list) else ():
        names += [entry.get("name"), entry.get("model")] if isinstance(entry, dict) else [entry]
    return _model_key(model) in {_model_key(n) for n in names if isinstance(n, str)}


async def probe() -> bool:
    """Whether hailo-ollama answers and lists CANARY_LLM_MODEL; remembered for chat() and the status."""
    global _online
    try:
        online = _listed(json.loads(await _call("/api/tags", None, PROBE_TIMEOUT_S)), settings.llm_model)
    except Exception:  # noqa: BLE001 - refused, timeout, not JSON: offline
        online = False
    if online and not _online:
        log.info("LLM %s online at %s", settings.llm_model, settings.llm_url)
    elif not online and _online is not False:
        log.log(logging.WARNING if _online else logging.INFO,
                "LLM %s not available at %s (down, or the model is not pulled): briefs use the template",
                settings.llm_model, settings.llm_url)
    _online = online
    return online


async def run_probe(stop: asyncio.Event) -> None:
    """Probe every PROBE_INTERVAL_S until `stop` (main.py starts it when CANARY_LLM_URL is set)."""
    while not stop.is_set():
        await probe()
        try:
            await asyncio.wait_for(stop.wait(), timeout=PROBE_INTERVAL_S)
        except asyncio.TimeoutError:
            pass


def _answer(raw: bytes) -> str:
    """The text of an /api/chat reply: `message.content` (or `response`, the /api/generate field)
    of one JSON document, or of every line when the server streams NDJSON anyway."""
    body = raw.decode("utf-8", "replace")
    try:
        docs = [json.loads(body)]
    except json.JSONDecodeError:
        docs = [json.loads(line) for line in body.splitlines() if line.strip()]
    parts = []
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        message = doc.get("message")
        part = message.get("content") if isinstance(message, dict) else doc.get("response")
        if isinstance(part, str):
            parts.append(part)
    return _THINK.sub("", "".join(parts)).strip()


async def chat(system: str, user: str) -> str | None:
    """The model's answer to a system and a user message, or None: no CANARY_LLM_URL, the probe found
    it offline, or the call failed, took longer than CHAT_TIMEOUT_S or came back empty."""
    if not settings.llm_url or _online is False:
        return None
    body = json.dumps({
        "model": settings.llm_model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "stream": False,
    }).encode()
    try:
        await asyncio.wait_for(_slot.acquire(), CHAT_TIMEOUT_S)
    except asyncio.TimeoutError:
        log.warning("LLM %s busy with other briefs: template instead", settings.llm_model)
        return None
    try:
        return _answer(await _call("/api/chat", body, CHAT_TIMEOUT_S)) or None
    except Exception as exc:  # noqa: BLE001 - the template takes over
        log.warning("LLM %s failed: %r", settings.llm_model, exc)
        return None
    finally:
        _slot.release()
