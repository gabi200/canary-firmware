from pathlib import Path

from updater import gitops
from updater.config import load_config
from updater.runner import Result, Runner
from updater.store import StateStore
from updater.tests.fakes import FakeRunner


def _cfg(tmp_path: Path, text: str):
    (tmp_path / ".env").write_text(text)
    return load_config(tmp_path, tmp_path, tmp_path / "state.json")


def test_load_config_triple(tmp_path):
    cfg = _cfg(tmp_path, "# comment\nCANARY_CLUSTER_MODE=triple\nCANARY_NODE_NAME=web\nCANARY_NODE_IP=10.0.0.12\n"
               "CANARY_PROCESSING_IP=10.0.0.11\nCANARY_WEB_IP=10.0.0.12\nCANARY_AI_IP=10.0.0.13\n\nCANARY_UPDATER_KEY=k\n")
    assert cfg.triple is True
    assert cfg.node == "web"
    assert cfg.node_ip == "10.0.0.12"
    assert cfg.peers == {"processing": "10.0.0.11", "web": "10.0.0.12", "ai": "10.0.0.13"}
    assert cfg.port == 8010
    assert cfg.key == "k"


def test_load_config_single(tmp_path):
    cfg = _cfg(tmp_path, "CANARY_UPDATER_KEY=k\n")
    assert (cfg.node, cfg.triple, cfg.peers) == ("hub", False, {"hub": "127.0.0.1"})


def test_counts_and_head_parse(tmp_path):
    r = FakeRunner()
    r.on(("git", "rev-list"), Result(0, "3\t1\n"))
    r.on(("git", "log", "-1"), Result(0, "a" * 40 + "\x1ffix it\x1f2026-11-02T10:00:00+02:00\n"))
    assert gitops.counts(r, tmp_path) == (3, 1)
    assert gitops.head(r, tmp_path) == {"sha": "a" * 40, "subject": "fix it", "date": "2026-11-02T10:00:00+02:00"}


def test_head_failure_is_none(tmp_path):
    r = FakeRunner()
    r.on(("git", "log", "-1"), Result(128, "bad"))
    assert gitops.head(r, tmp_path) is None


def test_incoming_parse(tmp_path):
    r = FakeRunner()
    r.on(("git", "log", "HEAD..origin/main"), Result(0, "b" * 40 + "\x1fnew\x1fGabi\x1f2026-11-02T11:00:00Z\n"))
    assert gitops.incoming(r, tmp_path) == [{"sha": "b" * 40, "subject": "new", "author": "Gabi",
                                             "date": "2026-11-02T11:00:00Z"}]


def test_sha_re():
    assert gitops.SHA_RE.match("a" * 40)
    for bad in ("a" * 39, "A" * 40, "main", "a" * 40 + ";rm"):
        assert not gitops.SHA_RE.match(bad)


def test_store_roundtrip_and_corrupt(tmp_path):
    store = StateStore(tmp_path / "x" / "state.json")
    assert store.load() == {}
    store.save({"state": "idle", "log": ["a"]})
    assert store.load() == {"state": "idle", "log": ["a"]}
    (tmp_path / "x" / "state.json").write_text("{")
    assert store.load() == {}


def test_real_runner_timeout_and_missing(tmp_path):
    assert Runner().run(["sleep", "5"], cwd=tmp_path, timeout=0.2).code == 124
    assert Runner().run(["no-such-binary-xyz"], cwd=tmp_path, timeout=5).code == 127
    assert Runner().run(["echo", "hi"], cwd=tmp_path, timeout=5) == Result(0, "hi\n")
