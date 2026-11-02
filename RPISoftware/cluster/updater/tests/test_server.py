import json
import threading
import time
import urllib.error
import urllib.request

import pytest

from updater.pi import PiUpdater
from updater.rollout import Rollout
from updater.runner import Result
from updater.server import make_server
from updater.store import StateStore
from updater.tests.conftest import make_cfg
from updater.tests.pifake import NEW, OLD, FakePi


@pytest.fixture
def hub(tmp_path, runner):
    cfg = make_cfg(tmp_path, triple=False)
    pi = FakePi(runner, cfg)
    local = PiUpdater(cfg, runner, StateStore(cfg.state_file))
    exits = []
    srv = make_server(cfg, local, Rollout(cfg, runner, local), "127.0.0.1", 0, exit_fn=exits.append)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", pi, local, exits
    srv.shutdown()


def call(base, method, path, body=None, key="k"):
    req = urllib.request.Request(base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Canary-Updater-Key": key} if key else {})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        raw = err.read()
        return err.code, json.loads(raw) if raw else None


def wait_idle(local):
    for _ in range(200):
        if local.state()["state"] not in ("updating", "rolling_back"):
            return
        time.sleep(0.01)


def test_wrong_key_is_404(hub):
    base, *_ = hub
    assert call(base, "GET", "/status", key="nope") == (404, None)
    assert call(base, "GET", "/status", key=None) == (404, None)


def test_bad_commit_is_422(hub):
    base, *_ = hub
    assert call(base, "POST", "/update", {"commit": "main"}) == (422, {"error": "commit must be a 40-character hex id"})


def test_update_returns_202_then_409_while_busy(hub, runner):
    base, pi, local, _ = hub
    gate = threading.Event()
    runner.on(("docker", "compose", "up"), lambda a: (gate.wait(5), Result(0, ""))[1])
    status, body = call(base, "POST", "/update", {"commit": NEW})
    assert (status, body["state"], body["target"]) == (202, "updating", NEW)
    assert call(base, "POST", "/rollout", {"commit": NEW}) == (409, {"error": "an update is already running on this Pi"})
    gate.set()
    wait_idle(local)
    assert local.state()["state"] == "idle"


def test_refused_is_409_with_reason(hub):
    base, pi, *_ = hub
    pi.dirty = True
    assert call(base, "POST", "/update", {"commit": NEW}) == (409, {"error": "this Pi has local changes"})


def test_status_shape(hub):
    base, *_ = hub
    status, body = call(base, "GET", "/status")
    assert status == 200
    assert {"node", "commit", "state", "behind", "ahead", "dirty", "rollout"} <= body.keys()
    assert body["commit"]["sha"] == OLD


def test_incoming(hub, runner):
    base, *_ = hub
    runner.on(("git", "log", "HEAD..origin/main"), Result(0, NEW + "\x1fnew\x1fGabi\x1f2026-11-02T11:00:00Z\n"))
    status, body = call(base, "GET", "/incoming")
    assert status == 200
    assert body["commits"][0]["sha"] == NEW
    assert "head" in body


def test_rollout_runs_and_restarts_when_updater_changed(hub, runner):
    base, pi, local, exits = hub
    runner.on(("git", "diff", "--name-only"), Result(0, "RPISoftware/cluster/updater/server.py\n"))
    assert call(base, "POST", "/rollout", {"commit": NEW})[0] == 202
    for _ in range(200):
        if exits:
            break
        time.sleep(0.01)
    assert local.state()["rollout"]["outcome"] == "done"
    assert exits == [0]


def test_dismiss(hub):
    base, pi, local, _ = hub
    local.update_state(state="rolled_back", error="x")
    status, body = call(base, "POST", "/dismiss")
    assert (status, body["state"]) == (200, "idle")


def test_job_exception_marks_failed(hub, runner):
    base, pi, local, _ = hub

    def boom(args):
        raise PermissionError("docker: permission denied")

    runner.on(("docker", "compose", "up"), boom)
    assert call(base, "POST", "/rollout", {"commit": NEW})[0] == 202
    for _ in range(200):
        if local.state()["state"] == "failed":
            break
        time.sleep(0.01)
    s = local.state()
    assert s["state"] == "failed"
    assert "permission denied" in s["error"]
    assert s["rollout"]["outcome"] == "stopped"
    assert call(base, "POST", "/update", {"commit": NEW}) == (409, {"error": "this Pi's last update failed: check it first"})


def test_check_and_health(hub, runner):
    base, pi, local, _ = hub
    assert call(base, "GET", "/health") == (200, {"problem": None})
    assert call(base, "POST", "/check", {"commit": NEW}) == (200, {})
    pi.known.discard(NEW)
    assert call(base, "POST", "/check", {"commit": NEW}) == (409, {"error": "unknown commit: fetch first"})
    assert runner.ran("git", "fetch")  # it fetched once before refusing
