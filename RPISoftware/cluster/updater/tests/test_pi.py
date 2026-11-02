import pytest

from updater.pi import PiUpdater, Refused
from updater.runner import Result
from updater.store import StateStore
from updater.tests.conftest import make_cfg
from updater.tests.pifake import NEW, OLD, FakePi


def setup(tmp_path, runner, **kw):
    cfg = make_cfg(tmp_path, **kw)
    pi = FakePi(runner, cfg)
    store = StateStore(cfg.state_file)
    return PiUpdater(cfg, runner, store), pi, store


def test_happy_path_single(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    up.begin(NEW)
    assert up.status()["state"] == "updating"
    up.run()
    s = up.status()
    assert (s["state"], s["step"], s["previous"], s["target"]) == ("idle", "done", OLD, NEW)
    assert s["commit"]["sha"] == NEW
    assert runner.index("git", "merge", "--ff-only") < runner.index("docker", "compose", "up")
    assert runner.calls[runner.index("git", "merge", "--ff-only")][-1] == NEW


def test_build_failure_rolls_back(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    pi.builds = [1]
    up.begin(NEW)
    up.run()
    s = up.status()
    assert runner.ran("git", "reset", "--hard", OLD)
    assert s["state"] == "rolled_back"
    assert s["error"].startswith("build failed")
    assert "ERROR: build broke" in s["error"]
    assert s["commit"]["sha"] == OLD


def test_unhealthy_rolls_back_after_timeout(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    pi.healthy_after_build = False
    up.begin(NEW)
    up.run()
    s = up.status()
    assert s["state"] == "rolled_back"
    assert "not healthy" in s["error"]
    assert runner.clock >= 300


def test_rollback_failure_is_failed(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    pi.builds = [1, 1]
    up.begin(NEW)
    up.run()
    s = up.status()
    assert s["state"] == "failed"
    assert "rollback also failed" in s["error"]


def test_git_failure_rolls_back(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    runner.on(("git", "merge", "--ff-only"), Result(128, "fatal: Not possible to fast-forward"))
    up.begin(NEW)
    up.run()
    s = up.status()
    assert (s["state"], s["error"]) == ("rolled_back", "git: fatal: Not possible to fast-forward")


@pytest.mark.parametrize("arrange, reason", [
    (lambda up, pi: up.store.save({"state": "updating"}), "an update is already running on this Pi"),
    (lambda up, pi: setattr(pi, "branch", "dev"), "not on branch main"),
    (lambda up, pi: setattr(pi, "dirty", True), "this Pi has local changes"),
    (lambda up, pi: pi.known.discard(NEW), "unknown commit: fetch first"),
])
def test_preflight_refusals(tmp_path, runner, arrange, reason):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    arrange(up, pi)
    with pytest.raises(Refused) as exc:
        up.begin(NEW)
    assert str(exc.value) == reason


def test_preflight_refuses_when_a_peer_is_unhealthy(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner)
    runner.on_http("GET", "http://10.0.0.13:8000/health", (0, {}))
    with pytest.raises(Refused, match="the ai Pi is not healthy"):
        up.begin(NEW)
    up.begin(NEW, check_peers=False)  # inside a rollout the coordinator checked already
    assert up.status()["state"] == "updating"


def test_leader_switches_over_first(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, node="web")
    pi.leader = "web"
    up.begin(NEW)
    up.run()
    i = runner.index("docker", "compose", "exec")
    assert runner.calls[i][-6:] == ["switchover", "--leader", "web", "--candidate", "ai", "--force"]
    assert i < runner.index("git", "merge", "--ff-only")
    assert up.status()["state"] == "idle"


def test_switchover_failure_changes_nothing(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, node="web")
    pi.leader, pi.switchover_works = "web", False
    up.begin(NEW)
    up.run()
    s = up.status()
    assert not runner.ran("git", "merge")
    assert s["state"] == "idle"
    assert s["error"].startswith("could not move the database")


def test_recover_marks_interrupted_failed(tmp_path, runner):
    up, pi, store = setup(tmp_path, runner, triple=False)
    store.save({"state": "updating", "step": "building"})
    up.recover()
    s = up.status()
    assert s["state"] == "failed"
    assert "stopped during the update" in s["error"]


def test_restart_needed_when_updater_changed(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    runner.on(("git", "diff", "--name-only"), Result(0, "RPISoftware/cluster/updater/pi.py\n"))
    up.begin(NEW)
    up.run()
    assert up.status()["restart_needed"] is True


def test_log_is_trimmed_and_dismiss(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    pi.healthy_after_build = False
    up.begin(NEW)
    up.run()
    assert 0 < len(up.status()["log"]) <= 50
    up.dismiss()
    s = up.status()
    assert (s["state"], s["error"]) == ("idle", None)


def test_fetch_records_time_and_error(tmp_path, runner):
    up, pi, _ = setup(tmp_path, runner, triple=False)
    up.fetch()
    assert up.status()["fetched_at"].endswith("Z")
    runner.on(("git", "fetch"), Result(128, "fatal: unable to access 'https://github.com/'\n"))
    up.fetch()
    assert up.status()["fetch_error"] == "fatal: unable to access 'https://github.com/'"
