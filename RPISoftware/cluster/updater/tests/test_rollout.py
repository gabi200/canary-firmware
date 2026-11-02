import pytest

from updater.pi import PiUpdater, Refused
from updater.rollout import Rollout
from updater.store import StateStore
from updater.tests.conftest import PEERS, make_cfg
from updater.tests.pifake import NEW, OLD, FakePi


class FakePeer:
    """Another Pi's helper: /update starts it, /status answers `polls` times before it finishes."""

    def __init__(self, runner, name, *, ends="idle", polls=1, gone=0):
        self.name, self.ends, self.polls, self.gone = name, ends, polls, gone
        self.st = {"node": name, "state": "idle", "target": None, "dirty": False, "branch": "main",
                   "commit": {"sha": OLD}, "error": None}
        ip = PEERS[name]
        runner.on_http("GET", f"http://{ip}:8010/status", self._status)
        runner.on_http("POST", f"http://{ip}:8010/update", self._update)

    def _update(self, body):
        self.st.update(state="updating", target=body["commit"])
        return 202, dict(self.st)

    def _status(self, _):
        if self.st["state"] == "updating":
            if self.gone:
                self.gone -= 1
                return 0, {}
            self.polls -= 1
            if self.polls < 0:
                self.st["state"] = self.ends
                if self.ends == "idle":
                    self.st["commit"] = {"sha": self.st["target"]}
                else:
                    self.st["error"] = "build failed: boom"
        return 200, dict(self.st)


def setup(tmp_path, runner, node="web", triple=True, leader="processing"):
    cfg = make_cfg(tmp_path, node=node, triple=triple)
    pi = FakePi(runner, cfg)
    pi.leader = leader
    local = PiUpdater(cfg, runner, StateStore(cfg.state_file))
    return Rollout(cfg, runner, local), local, pi


def test_order_puts_leader_last(tmp_path, runner):
    ro, _, _ = setup(tmp_path, runner, leader="processing")
    assert ro.order() == ["ai", "web", "processing"]


def test_single_order_is_hub(tmp_path, runner):
    ro, _, _ = setup(tmp_path, runner, triple=False)
    assert ro.order() == ["hub"]


def test_refuses_when_peer_unreachable(tmp_path, runner):
    ro, _, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    with pytest.raises(Refused, match="the ai Pi's updater does not answer"):
        ro.begin(NEW)


def test_refuses_when_peer_dirty(tmp_path, runner):
    ro, _, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    FakePeer(runner, "ai").st["dirty"] = True
    with pytest.raises(Refused, match="the ai Pi has local changes"):
        ro.begin(NEW)


def test_refuses_when_peer_failed(tmp_path, runner):
    ro, _, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing").st["state"] = "failed"
    FakePeer(runner, "ai")
    with pytest.raises(Refused, match="the processing Pi's last update failed"):
        ro.begin(NEW)


def test_runs_in_order_and_finishes(tmp_path, runner):
    ro, local, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    FakePeer(runner, "ai")
    ro.begin(NEW)
    assert local.state()["rollout"]["outcome"] == "running"
    ro.run()
    r = local.state()["rollout"]
    assert (r["outcome"], r["order"]) == ("done", ["ai", "web", "processing"])
    assert r["results"] == {"ai": "done", "web": "done", "processing": "done"}
    posts = [u for m, u, _ in runner.http_calls if m == "POST"]
    assert posts == ["http://10.0.0.13:8010/update", "http://10.0.0.11:8010/update"]
    assert local.status()["commit"]["sha"] == NEW  # this Pi updated in between


def test_stops_at_first_rollback(tmp_path, runner):
    ro, local, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    FakePeer(runner, "ai", ends="rolled_back")
    ro.begin(NEW)
    ro.run()
    r = local.state()["rollout"]
    assert (r["outcome"], r["reason"]) == ("stopped", "ai Pi: build failed: boom")
    assert r["results"] == {"ai": "rolled_back", "web": "waiting", "processing": "waiting"}
    assert [u for m, u, _ in runner.http_calls if m == "POST"] == ["http://10.0.0.13:8010/update"]
    assert local.status()["commit"]["sha"] == OLD


def test_stops_when_own_update_rolls_back(tmp_path, runner):
    ro, local, pi = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    FakePeer(runner, "ai")
    pi.builds = [1]
    ro.begin(NEW)
    ro.run()
    r = local.state()["rollout"]
    assert r["results"] == {"ai": "done", "web": "rolled_back", "processing": "waiting"}
    assert r["reason"].startswith("web Pi: build failed")


def test_tolerates_peer_restarting(tmp_path, runner):
    ro, local, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    FakePeer(runner, "ai", gone=3)
    ro.begin(NEW)
    ro.run()
    assert local.state()["rollout"]["results"]["ai"] == "done"


def test_peer_refusing_stops(tmp_path, runner):
    ro, local, _ = setup(tmp_path, runner)
    FakePeer(runner, "processing")
    FakePeer(runner, "ai")
    runner.on_http("POST", "http://10.0.0.13:8010/update", (409, {"error": "this Pi has local changes"}))
    ro.begin(NEW)
    ro.run()
    r = local.state()["rollout"]
    assert (r["outcome"], r["reason"], r["results"]["ai"]) == ("stopped", "ai Pi: this Pi has local changes", "failed")


def test_single_rollout_updates_hub(tmp_path, runner):
    ro, local, _ = setup(tmp_path, runner, triple=False)
    ro.begin(NEW)
    ro.run()
    assert local.state()["rollout"]["results"] == {"hub": "done"}
