"""Incident brief for responders (docs/AI_IDEAS.md, "Incident briefing for responders").

Two to four sentences from database facts only (app.api.ai reads them): hazard, state and severity,
where it is, the estimated source, the signature label, the people counts and the last timeline
events. The facts never carry names, notes, phone numbers or care data (dispatchers read the brief),
so neither the LLM nor the template can repeat any. This node's LLM writes it (app.ai.llm); without
one, or when it is offline, slow or answers nothing, the template does, instantly. Never in the
alarm path.
"""

from __future__ import annotations

import json

from app import cluster
from app.ai import llm
from app.config import settings
from app.i18n import translate

MAX_CHARS = 800

_LANGUAGE = {"ro": "Romanian", "en": "English"}
# Tokens as English words; each word is a key of the RO catalog (app.i18n).
_HAZARD = {  # as app.notify.service titles incidents
    "combustible_gas": "Gas leak",
    "co": "Carbon monoxide",
    "water_leak": "Water leak",
    "particulate": "Smoke / particulates",
}
_STATE = {"false_alarm": "false alarm"}  # the other states are English words already
_SIGNATURE = {  # normal / unknown are not worth a sentence
    "smouldering_fire": "a smouldering fire",
    "flaming_fire": "a flaming fire",
    "gas_leak": "a gas leak",
    "steam": "steam",
    "cooking": "cooking fumes",
    "aerosol": "an aerosol spray",
}


def _state(token: str | None, lang: str) -> str:
    return translate(lang, _STATE.get(token, token or ""))


def _words(facts: dict, lang: str) -> dict:
    """The facts with their tokens as words in `lang`: what the template says and the LLM reads."""
    hazard, signature = facts.get("hazard"), facts.get("signature")
    return {
        **facts,
        "hazard": translate(lang, _HAZARD.get(hazard, hazard or "")),
        "state": _state(facts.get("state"), lang),
        "severity": translate(lang, facts.get("severity") or ""),
        "zone": facts.get("zone") or translate(lang, "an unknown zone"),
        "signature": translate(lang, _SIGNATURE[signature]) if signature in _SIGNATURE else None,
        "timeline": [
            {**event, "state": _state(event.get("state"), lang),
             "reason": (event.get("reason") or "").replace("_", " ")}
            for event in facts.get("timeline") or []
        ],
    }


def template(facts: dict, lang: str) -> str:
    """The brief without an LLM: two to four fixed sentences in `lang`."""
    words = _words(facts, lang)
    sentences = [translate(
        lang, "{hazard} in {zone} since {time}; state: {state}, severity: {severity}.",
        hazard=words["hazard"], zone=words["zone"], time=facts.get("opened") or "?", state=words["state"],
        severity=words["severity"],
    )]
    if facts.get("source_zone") and facts.get("source_confidence") is not None:
        sentences.append(translate(lang, "Estimated source: {zone}, confidence {confidence}%.",
                                   zone=facts["source_zone"], confidence=round(100 * facts["source_confidence"])))
    if words["signature"]:
        sentences.append(translate(lang, "The sensor pattern resembles {signature}.", signature=words["signature"]))
    people = facts.get("people") or {}
    sentences.append(translate(
        lang,
        "People present (estimate): {present_estimate}; confirmed safe: {confirmed_safe}; "
        "need help: {need_help}; unaccounted: {unaccounted}.",
        **{key: people.get(key, 0) for key in ("present_estimate", "confirmed_safe", "need_help", "unaccounted")},
    ))
    return " ".join(sentences)


def prompt(facts: dict, lang: str) -> tuple[str, str]:
    """(system, user) messages for the LLM: how to write, and the facts as compact JSON."""
    system = (
        f"You write incident briefs for emergency responders. Write 2 to 4 short sentences in "
        f"{_LANGUAGE[lang]}, using only the facts in the JSON message. Never invent people, places, "
        "numbers, times or causes; leave out what the facts do not say. Plain text, no lists or headings."
    )
    return system, json.dumps(_words(facts, lang), ensure_ascii=False, separators=(",", ":"))


def _cap(text: str) -> str:
    """At most MAX_CHARS: cut after the last whole sentence that fits."""
    if len(text) <= MAX_CHARS:
        return text
    end = max(text.rfind(". ", 0, MAX_CHARS + 1), text.rfind(".\n", 0, MAX_CHARS + 1))
    return text[: end + 1] if end > 0 else text[: MAX_CHARS - 1].rstrip() + "…"


async def generate(facts: dict, lang: str) -> dict:
    """The brief in `lang` (ro | en, anything else is English) as {"text", "source": "llm" | "template",
    "model", "node"}; `node` is this node, the one that wrote it."""
    lang = lang if lang in _LANGUAGE else "en"
    text = await llm.chat(*prompt(facts, lang))
    if text:
        return {"text": _cap(text), "source": "llm", "model": settings.llm_model, "node": cluster.node_name()}
    return {"text": template(facts, lang), "source": "template", "model": None, "node": cluster.node_name()}
