"""AI offload (app.ai.offload): here in single mode, the AI node's answer when it gives one, the same
local result plus a 15 s breaker when it fails, and exact JSON round trips."""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from sqlalchemy import select

from app import cluster
from app.ai import offload
from app.analytics.signature import model as signature_model
from app.analytics.signature.features import extract_features
from app.analytics.triangulation import SensorPoint, triangulate
from app.config import settings
from app.db import SessionLocal
from app.ingestion import hardware
from app.models import SignatureAssessmentRow
from tests.conftest import auth_token, telemetry
from tests.signature_windows import SCENARIOS, publish, scenario_snapshots, seed_history

PEER = "http://192.0.2.13:8000"  # TEST-NET-1: never contacted, call_peer is replaced
# the seed's floor-3 layout and a kitchen gas leak spreading toward the hallway and the boiler room
ZONES = {"zone_kitchen": (2.0, 2.0), "zone_bedroom": (8.0, 2.0), "zone_hallway": (5.0, 5.0),
         "zone_boiler": (2.0, 8.0)}
SENSORS = [
    SensorPoint("dev_gas_kitchen", "zone_kitchen", 2.0, 2.0, value=5873.25, baseline=1000.0,
                detected_ts=1791874800.125),
    SensorPoint("dev_gas_hallway", "zone_hallway", 5.0, 5.0, value=2210.7, baseline=1000.0,
                detected_ts=1791874817.5),
    SensorPoint("dev_gas_boiler", "zone_boiler", 2.0, 8.0, value=1333.3, baseline=1000.0, detected_ts=1791874841.0),
    SensorPoint("dev_gas_bedroom", "zone_bedroom", 8.0, 2.0, value=640.0, baseline=1000.0),  # under threshold
]


@pytest.fixture(autouse=True)
def _closed_breaker(monkeypatch):
    monkeypatch.setattr(offload, "_skip_until", 0.0)
    monkeypatch.setattr(offload, "_failing", False)


@pytest.fixture
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


def wire(data):
    """What JSON over HTTP makes of `data`."""
    return json.loads(json.dumps(data, separators=(",", ":")))


@pytest.fixture
def peer(monkeypatch) -> list[tuple[str, str, dict, float]]:
    """The AI node as a loopback: payload and result cross JSON as on the wire, the task runs here."""
    calls: list[tuple[str, str, dict, float]] = []

    async def call_peer(base_url: str, path: str, payload: dict, timeout: float) -> dict:
        calls.append((base_url, path, payload, timeout))
        return wire(await offload.run_local(path.removeprefix("/internal/ai/"), wire(payload)))

    monkeypatch.setattr(cluster, "ai_peer", lambda: PEER)
    monkeypatch.setattr(cluster, "call_peer", call_peer)
    return calls


def ai_node(monkeypatch, answer) -> list[str]:
    """An AI node that answers `answer` (an exception is raised); returns the paths asked."""
    asked: list[str] = []

    async def call_peer(base_url: str, path: str, payload: dict, timeout: float):
        asked.append(path)
        if isinstance(answer, BaseException):
            raise answer
        return answer

    monkeypatch.setattr(cluster, "ai_peer", lambda: PEER)
    monkeypatch.setattr(cluster, "call_peer", call_peer)
    return asked


async def test_single_mode_computes_here(monkeypatch):
    async def no_peer(*args):
        raise AssertionError("single mode must not call another node")

    monkeypatch.setattr(cluster, "call_peer", no_peer)
    assert cluster.ai_peer() is None
    assert await offload.triangulate(SENSORS, ZONES) == triangulate(SENSORS, ZONES)
    features = extract_features(scenario_snapshots("steam"))
    assert await offload.signature_shadow(features) == signature_model.predict(features)
    assert await offload.compute("triangulate", offload.triangulation_payload(SENSORS, ZONES)) == asdict(
        triangulate(SENSORS, ZONES))


async def test_unknown_tasks_are_key_errors_and_bad_payloads_are_not(peer):
    with pytest.raises(KeyError):
        await offload.run_local("forecast", {})
    with pytest.raises(KeyError):
        await offload.compute("forecast", {})
    assert peer == []  # an unknown task is never sent
    with pytest.raises(ValueError):  # POST /internal/ai/{task} answers 404 only for KeyError
        await offload.run_local("triangulate", {"zones": {}})


async def test_triangulation_over_the_wire_equals_a_local_call(peer):
    local = triangulate(SENSORS, ZONES)
    assert local.source_zone_id == "zone_kitchen" and local.n_contributors == 3  # a real estimate
    assert await offload.triangulate(SENSORS, ZONES) == local
    assert [(base, path, timeout) for base, path, _, timeout in peer] == [
        (PEER, "/internal/ai/triangulate", offload.TIMEOUT_S)]
    assert peer[0][2]["zones"]["zone_kitchen"] == [2.0, 2.0]  # zones {id: [x, y]}


@pytest.mark.parametrize("scenario", sorted(SCENARIOS))
async def test_shadow_prediction_over_the_wire_equals_a_local_call(peer, scenario):
    features = extract_features(scenario_snapshots(scenario))
    local = signature_model.predict(features)
    assert local is not None
    assert await offload.signature_shadow(features) == local
    assert [path for _, path, _, _ in peer] == ["/internal/ai/signature_shadow"]


async def test_no_shadow_model_crosses_the_wire_as_none(peer, monkeypatch):
    monkeypatch.setattr(signature_model, "predict", lambda features, path=None: None)
    features = extract_features(scenario_snapshots("cooking"))
    assert await offload.run_local("signature_shadow", asdict(features)) == {}
    assert await offload.signature_shadow(features) is None
    assert len(peer) == 1


async def test_the_ai_nodes_answer_is_used(monkeypatch):
    remote = triangulate(SENSORS[1:], ZONES)  # visibly not what this node would compute
    assert remote != triangulate(SENSORS, ZONES)
    ai_node(monkeypatch, wire(asdict(remote)))
    assert await offload.triangulate(SENSORS, ZONES) == remote


async def test_a_failing_ai_node_means_here_and_is_skipped_for_15_s(monkeypatch, caplog):
    clock = [5000.0]
    monkeypatch.setattr(offload, "monotonic", lambda: clock[0])
    asked = ai_node(monkeypatch, TimeoutError())
    local = triangulate(SENSORS, ZONES)
    with caplog.at_level(logging.INFO, logger="canary.ai"):
        assert await offload.triangulate(SENSORS, ZONES) == local  # the work is never lost
        clock[0] += 14.9
        assert await offload.triangulate(SENSORS, ZONES) == local
        assert asked == ["/internal/ai/triangulate"]  # the breaker skipped the AI node
        clock[0] += 0.2
        assert await offload.triangulate(SENSORS, ZONES) == local
        assert len(asked) == 2  # asked again after 15 s, failed again: still one warning
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert len(warnings) == 1 and PEER in warnings[0].getMessage()

        recovered = ai_node(monkeypatch, wire(asdict(local)))
        clock[0] += 15.1
        assert await offload.triangulate(SENSORS, ZONES) == local
        assert recovered == ["/internal/ai/triangulate"]
        assert any("answers again" in r.getMessage() for r in caplog.records)


@pytest.mark.parametrize(("task", "answer"), [
    ("triangulate", {}),
    ("triangulate", {"source_x": 1.0}),
    ("triangulate", ["not", "an", "object"]),
    ("signature_shadow", {"label": "steam"}),
    ("signature_shadow", {"label": "steam", "confidence": 0.9, "model_version": "v1", "extra": 1}),
    ("brief", {"text": "", "source": "llm", "model": None, "node": "ai"}),
    ("brief", {"text": "Ok.", "source": "cloud", "model": None, "node": "ai"}),
])
async def test_a_malformed_answer_means_here(monkeypatch, task, answer):
    monkeypatch.setattr(settings, "llm_url", "")
    ai_node(monkeypatch, answer)
    if task == "triangulate":
        assert await offload.triangulate(SENSORS, ZONES) == triangulate(SENSORS, ZONES)
    elif task == "signature_shadow":
        features = extract_features(scenario_snapshots("steam"))
        assert await offload.signature_shadow(features) == signature_model.predict(features)
    else:
        result = await offload.write_brief({"hazard": "co", "state": "alarm"}, "en")
        assert (result["source"], result["node"]) == ("template", "hub")
    assert offload._skip_until > 0  # and the breaker is open


async def test_a_slow_ai_node_costs_about_a_second(monkeypatch):
    """The real cluster.call_peer against a node that answers after 5 s."""
    release = threading.Event()

    class Slow(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            release.wait(5)
            try:
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
            except OSError:  # the hub gave up already
                pass

        def log_message(self, *args) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
    monkeypatch.setattr(cluster, "ai_peer", lambda: f"http://127.0.0.1:{server.server_address[1]}")
    try:
        start = time.monotonic()
        assert await offload.triangulate(SENSORS, ZONES) == triangulate(SENSORS, ZONES)
        assert time.monotonic() - start < offload.TIMEOUT_S + 1.0
    finally:
        release.set()
        server.shutdown()
        server.server_close()


async def test_incident_triangulation_through_the_ai_node(client, peer):
    hdr = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_boiler", "combustible_gas", 1500, zone_id="zone_boiler", unit_id="common", seq=1))
    r = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312",
        seq=2, edge_state="alarm"))
    inc = (await client.get(f"/api/v1/incidents/{r.json()['incident_id']}", headers=hdr)).json()
    assert inc["state"] == "evacuation" and inc["est_source_zone_id"] == "zone_kitchen"
    assert "/internal/ai/triangulate" in [path for _, path, _, _ in peer]


@pytest.mark.parametrize("node", ["loopback", "dead"])
async def test_the_ai_node_never_changes_the_safety_path(client, monkeypatch, _fresh_hub_state, node):
    """A held steam escalation stays held whether the AI node answers or is down, and the stored
    shadow opinion is the local model's either way."""
    if node == "loopback":
        asked = []

        async def call_peer(base_url, path, payload, timeout):
            asked.append(path)
            return wire(await offload.run_local(path.removeprefix("/internal/ai/"), wire(payload)))

        monkeypatch.setattr(cluster, "ai_peer", lambda: PEER)
        monkeypatch.setattr(cluster, "call_peer", call_peer)
    else:
        asked = ai_node(monkeypatch, ConnectionRefusedError(111, "Connection refused"))
    for doc in await seed_history("steam"):
        await publish("canary", doc)

    hdr = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    [inc] = (await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True}, headers=hdr)).json()
    assert (inc["hazard_type"], inc["state"]) == ("particulate", "verification")
    async with SessionLocal() as s:
        rows = (await s.scalars(select(SignatureAssessmentRow).where(
            SignatureAssessmentRow.incident_id == inc["id"]).order_by(SignatureAssessmentRow.id))).all()
    assert len(rows) == 3 and rows[-1].label == "steam"
    expected = signature_model.predict(extract_features(scenario_snapshots("steam")))
    assert rows[-1].model_version == expected.model_version and rows[-1].shadow_label is not None
    assert "/internal/ai/signature_shadow" in asked
