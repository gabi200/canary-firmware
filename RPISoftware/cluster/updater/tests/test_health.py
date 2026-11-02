import json

from updater import health
from updater.runner import Result
from updater.tests.conftest import make_cfg

SINGLE = ("mosquitto", "backend", "web")
CLUSTER = SINGLE + ("etcd", "postgres", "pgproxy", "keepalived")


def rows(services, **override):
    out = []
    for s in services:
        row = {"Service": s, "State": "running", "Health": "healthy" if s != "etcd" else ""}
        row.update(override.get(s, {}))
        out.append(row)
    return out


def ps(runner, data, array=False):
    text = json.dumps(data) if array else "\n".join(json.dumps(d) for d in data)
    runner.on(("docker", "compose", "ps"), Result(0, text))


def test_compose_lines_and_array_both_parse(tmp_path, runner):
    cfg = make_cfg(tmp_path, triple=False)
    ps(runner, rows(SINGLE))
    assert health.compose_problem(cfg, runner) is None
    ps(runner, rows(SINGLE), array=True)
    assert health.compose_problem(cfg, runner) is None


def test_compose_reports_unhealthy(tmp_path, runner):
    ps(runner, rows(SINGLE, backend={"Health": "starting"}))
    assert health.compose_problem(make_cfg(tmp_path, triple=False), runner) == "backend is starting"


def test_compose_reports_not_running(tmp_path, runner):
    ps(runner, rows(SINGLE, web={"State": "exited", "Health": ""}))
    assert health.compose_problem(make_cfg(tmp_path, triple=False), runner) == "web is exited"


def test_compose_reports_missing(tmp_path, runner):
    ps(runner, rows(("mosquitto", "backend")))
    assert health.compose_problem(make_cfg(tmp_path, triple=False), runner) == "web is missing"


def test_triple_expects_cluster_services(tmp_path, runner):
    ps(runner, rows(tuple(s for s in CLUSTER if s != "postgres")))
    assert health.compose_problem(make_cfg(tmp_path), runner) == "postgres is missing"


def test_backend_health(tmp_path, runner):
    cfg = make_cfg(tmp_path, triple=False)
    assert health.backend_problem(cfg, runner) == "the backend does not answer /health"
    runner.on_http("GET", "http://127.0.0.1:8000/health", (200, {"status": "ok"}))
    assert health.backend_problem(cfg, runner) is None


def members(state):
    return {"members": [{"name": "web", "role": "replica", "state": state},
                        {"name": "processing", "role": "leader", "state": "running"}]}


def test_patroni_replica_streaming_ok_and_stopped_not(tmp_path, runner):
    cfg = make_cfg(tmp_path)
    runner.on_http("GET", "http://10.0.0.11:8008/cluster", (200, members("streaming")))
    assert health.patroni_problem(cfg, runner) is None
    runner.on_http("GET", "http://10.0.0.11:8008/cluster", (200, members("stopped")))
    assert "stopped" in health.patroni_problem(cfg, runner)


def test_patroni_tries_next_peer(tmp_path, runner):
    runner.on_http("GET", "http://10.0.0.12:8008/cluster", (200, members("running")))
    assert health.patroni_members(make_cfg(tmp_path), runner)[1]["role"] == "leader"


def test_patroni_not_checked_on_one_pi(tmp_path, runner):
    assert health.patroni_problem(make_cfg(tmp_path, triple=False), runner) is None


def test_peer_problem(tmp_path, runner):
    cfg = make_cfg(tmp_path)
    assert health.peer_problem(cfg, runner, "ai") == "the ai Pi is not healthy"
    runner.on_http("GET", "http://10.0.0.13:8000/health", (200, {"status": "ok"}))
    assert health.peer_problem(cfg, runner, "ai") is None
