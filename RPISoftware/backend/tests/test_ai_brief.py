"""Incident brief (GET /api/v1/incidents/{id}/brief): the template in Romanian and English, the LLM
on a fake hailo-ollama and every way it falls back to the template, the probe, the AI node, roles,
and no personal data for dispatchers."""

from __future__ import annotations

import asyncio
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from app import cluster
from app.ai import brief, llm, offload
from app.config import settings
from app.ingestion import hardware
from tests.conftest import auth_token, telemetry
from tests.signature_windows import publish, seed_history

MODEL = "qwen2.5-instruct:1.5b"
ANSWER = "Scurgere de gaz în bucătăria din Ap. 12; clădirea se evacuează. Două persoane sunt încă neconfirmate."
NOTE = "Insulina in frigider, cheia la vecina de la 13"
# personal data in the seed and in _incident(): never in a brief, nor in what the LLM is sent
PERSONAL = ("Ana Popescu", "Ioana Popescu", "Radu Ionescu", "Elena Dumitru", "Popescu", "Ionescu", "Dumitru",
            "Bunica", "+4070000000", "0744 555 666", "usr_", NOTE, "Insulina")  # whole numbers: ids are hex
FIRST_NAMES = re.compile(r"\b(Ana|Ioana|Radu|Elena|Maria)\b")


class FakeOllama:
    """hailo-ollama on 127.0.0.1: GET /api/tags lists `models`; POST /api/chat answers `reply` (a
    document or raw bytes) with `status` after `delay_s`, and keeps each request body."""

    def __init__(self, reply: dict | bytes | None = None, models: tuple[str, ...] = (MODEL,), status: int = 200,
                 delay_s: float = 0.0) -> None:
        self.reply = {"model": MODEL, "message": {"role": "assistant", "content": ANSWER}, "done": True} \
            if reply is None else reply
        self.models, self.status, self.delay_s = models, status, delay_s
        self.chats: list[dict] = []
        self.release = threading.Event()
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                if self.path == "/api/tags":
                    self._send(200, {"models": [{"name": m, "model": m, "size": 1} for m in fake.models]})
                else:
                    self._send(404, {"error": "not found"})

            def do_POST(self) -> None:  # noqa: N802
                fake.chats.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                if fake.delay_s:
                    fake.release.wait(fake.delay_s)
                self._send(fake.status, fake.reply)

            def _send(self, code: int, doc: dict | bytes) -> None:
                raw = doc if isinstance(doc, bytes) else json.dumps(doc).encode()
                try:
                    self.send_response(code)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                except OSError:  # the hub gave up already
                    pass

            def log_message(self, *args) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()

    def stop(self) -> None:
        self.release.set()
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture(autouse=True)
def _no_llm(monkeypatch):
    """No CANARY_LLM_URL, nothing probed, the AI node breaker closed: each test sets what it needs."""
    monkeypatch.setattr(settings, "llm_url", "")
    monkeypatch.setattr(llm, "_online", None)
    monkeypatch.setattr(offload, "_skip_until", 0.0)
    monkeypatch.setattr(offload, "_failing", False)


@pytest.fixture
def ollama(monkeypatch):
    started: list[FakeOllama] = []

    def start(**kwargs) -> FakeOllama:
        fake = FakeOllama(**kwargs)
        started.append(fake)
        monkeypatch.setattr(settings, "llm_url", fake.url)
        return fake

    yield start
    for fake in started:
        fake.stop()


@pytest.fixture
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


def assert_private(text: str) -> None:
    for needle in PERSONAL:
        assert needle not in text, needle
    assert not FIRST_NAMES.search(text), FIRST_NAMES.search(text)


async def _hdr(client, user: str, lang: str | None = None) -> dict:
    headers = {"Authorization": f"Bearer {await auth_token(client, user)}"}
    return {**headers, "Accept-Language": lang} if lang else headers


async def _incident(client) -> str:
    """An evacuating kitchen gas leak with 3 people present, then personal data the brief must leave
    out: a phone number, a care profile with a note in Ap. 12 and Ana's check-in."""
    for device, zone, unit, persons in (("dev_presence_unit", "zone_hallway", "common", 2),
                                        ("dev_presence_bedroom", "zone_bedroom", "unit_0312", 1)):
        await client.post("/api/v1/telemetry", json=telemetry(
            device, "wifi_presence", persons, zone_id=zone, unit_id=unit, units="persons_est", seq=1))
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    incident_id = r.json()["incident_id"]
    ana = await _hdr(client, "ana")
    assert (await client.patch("/api/v1/me", json={"phone": "0744 555 666"}, headers=ana)).status_code == 200
    assert (await client.post("/api/v1/me/care-profiles", headers=ana, json={
        "unit_id": "unit_0312", "display_name": "Bunica Maria", "is_self": False, "needs": ["wheelchair"],
        "note": NOTE, "consent": True})).status_code == 201
    r = await client.post(f"/api/v1/incidents/{incident_id}/checkin", json={"status": "safe_outside"}, headers=ana)
    assert r.status_code == 200, r.text
    return incident_id


async def _brief(client, incident_id: str, user: str = "mihai", lang: str | None = None) -> dict:
    r = await client.get(f"/api/v1/incidents/{incident_id}/brief", headers=await _hdr(client, user, lang))
    assert r.status_code == 200, r.text
    assert_private(r.text)
    return r.json()


async def test_template_brief_in_english_and_romanian(client):
    incident_id = await _incident(client)
    en = await _brief(client, incident_id, lang="en")
    assert set(en) == {"incident_id", "text", "source", "model", "node", "generated_ts"}
    assert (en["incident_id"], en["source"], en["model"], en["node"]) == (incident_id, "template", None, "hub")
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", en["generated_ts"])
    assert re.match(r"Gas leak in Bucătărie \(Ap\. 12\) since (\d{4}-\d\d-\d\d )?\d\d:\d\d; "
                    r"state: evacuation, severity: critical\. Estimated source: Bucătărie \(Ap\. 12\), "
                    r"confidence \d+%\. People present \(estimate\): 3; confirmed safe: 1; need help: 0; "
                    r"unaccounted: 2\.$", en["text"]), en["text"]

    ro = await _brief(client, incident_id, lang="ro-RO,ro;q=0.9,en;q=0.5")
    assert re.match(r"Scurgere de gaz în Bucătărie \(Ap\. 12\) din (\d{4}-\d\d-\d\d )?\d\d:\d\d; "
                    r"stare: evacuare, severitate: critică\. Sursa estimată: Bucătărie \(Ap\. 12\), "
                    r"încredere \d+%\. Persoane prezente \(estimare\): 3; în siguranță: 1; cer ajutor: 0; "
                    r"neconfirmate: 2\.$", ro["text"]), ro["text"]

    assert (await _brief(client, incident_id))["text"] == en["text"]  # no Accept-Language: English


async def test_template_names_the_signature(client, _fresh_hub_state):
    for doc in await seed_history("steam"):
        await publish("canary", doc)
    r = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True},
                         headers=await _hdr(client, "mihai"))
    [inc] = r.json()
    en = (await _brief(client, inc["id"], lang="en"))["text"]
    assert en.startswith("Smoke / particulates in Hol scară (Spații comune) since ")
    assert "state: verification" in en and "The sensor pattern resembles steam." in en
    assert "Estimated source" not in en  # particulates are not triangulated
    ro = (await _brief(client, inc["id"], lang="ro"))["text"]
    assert ro.startswith("Fum / particule în Hol scară (Spații comune) din ")
    assert "stare: verificare" in ro and "Tiparul senzorilor seamănă cu abur." in ro


async def test_roles_and_unknown_incidents(client):
    incident_id = await _incident(client)
    url = f"/api/v1/incidents/{incident_id}/brief"
    for user, code in (("mihai", 200), ("dispecer", 200), ("admin", 200), ("ana", 403), ("tehnician", 403)):
        assert (await client.get(url, headers=await _hdr(client, user))).status_code == code, user
    assert (await client.get(url)).status_code == 401
    r = await client.get("/api/v1/incidents/inc_unknown/brief", headers=await _hdr(client, "dispecer"))
    assert r.status_code == 404


async def test_dispatchers_read_the_brief_without_personal_data(client, ollama):
    fake = ollama()
    incident_id = await _incident(client)
    for lang in ("ro", "en"):
        assert (await _brief(client, incident_id, "dispecer", lang))["source"] == "llm"
    sent = json.dumps(fake.chats, ensure_ascii=False)
    assert "Bucătărie (Ap. 12)" in sent  # what the LLM gets: places and counts...
    assert_private(sent)  # ...never people


async def test_the_llm_writes_the_brief(client, ollama):
    fake = ollama()
    incident_id = await _incident(client)
    out = await _brief(client, incident_id, "dispecer", "ro")
    assert (out["text"], out["source"], out["model"], out["node"]) == (ANSWER, "llm", MODEL, "hub")

    [chat] = fake.chats
    assert (chat["model"], chat["stream"]) == (MODEL, False)
    system, user = chat["messages"]
    assert (system["role"], user["role"]) == ("system", "user")
    assert "Romanian" in system["content"] and "Never invent people, places, numbers" in system["content"]
    facts = json.loads(user["content"])
    assert (facts["hazard"], facts["state"], facts["severity"], facts["zone"]) == (
        "Scurgere de gaz", "evacuare", "critică", "Bucătărie (Ap. 12)")
    assert facts["source_zone"] == "Bucătărie (Ap. 12)" and 0 < facts["source_confidence"] <= 1
    assert facts["people"] == {"present_estimate": 3, "confirmed_safe": 1, "need_help": 0, "unaccounted": 2}
    assert facts["timeline"][0]["state"] == "detectare" and facts["timeline"][-1]["state"] == "evacuare"
    assert all(set(event) == {"time", "state", "reason"} for event in facts["timeline"])

    await _brief(client, incident_id, "dispecer", "en")
    assert "English" in fake.chats[-1]["messages"][0]["content"]
    assert json.loads(fake.chats[-1]["messages"][1]["content"])["hazard"] == "Gas leak"


async def test_a_slow_llm_gives_the_template(client, ollama, monkeypatch):
    monkeypatch.setattr(llm, "CHAT_TIMEOUT_S", 0.3)
    fake = ollama(delay_s=5)
    incident_id = await _incident(client)
    start = time.monotonic()
    out = await _brief(client, incident_id, lang="en")
    assert time.monotonic() - start < 2.5
    assert (out["source"], out["model"]) == ("template", None) and out["text"].startswith("Gas leak in ")
    assert len(fake.chats) == 1


@pytest.mark.parametrize(("reply", "status"), [
    ({"error": "model 'qwen2.5-instruct:1.5b' not found"}, 404),
    ({"error": "device busy"}, 500),
    ({"model": MODEL, "message": {"role": "assistant", "content": "   "}, "done": True}, 200),
    ({"model": MODEL, "message": {"role": "assistant", "content": "<think>Facts say...</think>"}}, 200),
    (b"<html>502 Bad Gateway</html>", 200),
])
async def test_llm_failures_give_the_template(client, ollama, reply, status):
    fake = ollama(reply=reply, status=status)
    incident_id = await _incident(client)
    out = await _brief(client, incident_id, lang="ro")
    assert (out["source"], out["model"]) == ("template", None) and out["text"].startswith("Scurgere de gaz ")
    assert len(fake.chats) == 1


async def test_an_llm_the_probe_found_offline_is_not_asked(client, ollama):
    fake = ollama(models=("llama3.2:3b",))  # the configured model is not pulled
    assert await llm.probe() is False
    incident_id = await _incident(client)
    assert (await _brief(client, incident_id))["source"] == "template"
    assert fake.chats == []


async def test_probe_and_accelerator_status(ollama, monkeypatch):
    assert llm.accelerator_status() is None  # no CANARY_LLM_URL
    fake = ollama(models=("llama3.2:3b", MODEL))
    assert llm.accelerator_status() == {"kind": "hailo-ollama", "online": False, "model": MODEL}  # not probed yet
    assert await llm.probe() is True
    assert llm.accelerator_status() == {"kind": "hailo-ollama", "online": True, "model": MODEL}
    fake.models = ("llama3.2:3b",)
    assert await llm.probe() is False and llm.accelerator_status()["online"] is False
    monkeypatch.setattr(settings, "llm_url", "http://127.0.0.1:9")  # discard port: refused
    assert await llm.probe() is False


@pytest.mark.parametrize(("tags", "listed"), [
    ({"models": [{"name": MODEL, "model": MODEL, "size": 1}]}, True),
    ({"models": [{"model": MODEL.upper()}]}, True),
    ({"models": [f"{MODEL}:latest"]}, True),
    ([{"name": MODEL}], True),
    ({"models": [{"name": "qwen2:1.5b"}]}, False),
    ({"models": None}, False),
    ({}, False),
    (MODEL, False),
])
def test_tags_answers_are_read_leniently(tags, listed):
    assert llm._listed(tags, MODEL) is listed


async def test_run_probe_probes_until_stopped(ollama):
    ollama()
    stop = asyncio.Event()
    task = asyncio.create_task(llm.run_probe(stop))
    for _ in range(100):
        if llm._online:
            break
        await asyncio.sleep(0.02)
    assert llm.accelerator_status()["online"] is True
    stop.set()
    await asyncio.wait_for(task, 1)


def test_chat_replies_are_read_leniently():
    def doc(**fields) -> bytes:
        return json.dumps(fields).encode()

    assert llm._answer(doc(message={"role": "assistant", "content": " Ok. "})) == "Ok."
    assert llm._answer(doc(response="Ok.")) == "Ok."  # the /api/generate field
    assert llm._answer(b"\n".join(doc(message={"content": part}) for part in ("Gas ", "leak."))) == "Gas leak."
    assert llm._answer(doc(message={"content": "<think>x\ny</think>Brief."})) == "Brief."


def test_long_answers_are_cut_after_a_sentence():
    text = " ".join(f"Sentence number {i} says something." for i in range(60))
    capped = brief._cap(text)
    assert len(capped) <= brief.MAX_CHARS and capped.endswith("something.") and text.startswith(capped)
    assert brief._cap("Short.") == "Short."
    assert len(brief._cap("x" * 2000)) == brief.MAX_CHARS


async def test_the_ai_node_writes_the_brief(client, monkeypatch):
    incident_id = await _incident(client)
    sent: list[tuple[str, dict, float]] = []

    async def call_peer(base_url: str, path: str, payload: dict, timeout: float) -> dict:
        sent.append((path, payload, timeout))
        return {"text": "Scurgere de gaz în Ap. 12.", "source": "llm", "model": MODEL, "node": "ai"}

    monkeypatch.setattr(cluster, "ai_peer", lambda: "http://192.0.2.13:8000")
    monkeypatch.setattr(cluster, "call_peer", call_peer)
    out = await _brief(client, incident_id, "dispecer", "ro")
    assert (out["text"], out["source"], out["model"], out["node"]) == (
        "Scurgere de gaz în Ap. 12.", "llm", MODEL, "ai")
    [(path, payload, timeout)] = sent
    assert (path, payload["lang"], timeout) == ("/internal/ai/brief", "ro", offload.BRIEF_TIMEOUT_S)
    assert payload["facts"]["hazard"] == "combustible_gas"  # tokens on the wire; the writer words them
    assert_private(json.dumps(payload, ensure_ascii=False))


async def test_a_dead_ai_node_gives_this_nodes_brief(client, monkeypatch):
    incident_id = await _incident(client)

    async def refused(*args) -> dict:
        raise ConnectionRefusedError(111, "Connection refused")

    monkeypatch.setattr(cluster, "ai_peer", lambda: "http://192.0.2.13:8000")
    monkeypatch.setattr(cluster, "call_peer", refused)
    out = await _brief(client, incident_id, lang="en")
    assert (out["source"], out["model"], out["node"]) == ("template", None, "hub")
    assert out["text"].startswith("Gas leak in Bucătărie (Ap. 12) since ")
