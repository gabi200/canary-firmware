"""A fake Pi: a git checkout that moves between commits, and containers that can be made unhealthy."""

from __future__ import annotations

import json

from updater.health import EXPECTED_SINGLE, EXPECTED_TRIPLE
from updater.runner import Result
from updater.tests.fakes import FakeRunner

OLD, NEW = "a" * 40, "b" * 40
SEP = "\x1f"


class FakePi:
    def __init__(self, runner: FakeRunner, cfg, *, head: str = OLD) -> None:
        self.r, self.cfg = runner, cfg
        self.head = head
        self.branch = "main"
        self.dirty = False
        self.known = {OLD, NEW}  # commits on origin/main
        self.builds: list[int] = []  # exit codes of the next builds; empty = success
        self.healthy_after_build = True
        self.healthy = True
        self.leader = "processing"
        r = runner
        r.on(("git", "log", "-1"), lambda a: Result(0, f"{self.head}{SEP}subject {self.head[:1]}{SEP}2026-11-02T10:00:00Z\n"))
        r.on(("git", "rev-parse", "--abbrev-ref"), lambda a: Result(0, self.branch + "\n"))
        r.on(("git", "status"), lambda a: Result(0, " M x\n" if self.dirty else ""))
        r.on(("git", "rev-list"), Result(0, "0\t0\n"))
        r.on(("git", "merge-base"), lambda a: Result(0 if a[-2] in self.known else 1, ""))
        r.on(("git", "merge", "--ff-only"), self._move)
        r.on(("git", "reset", "--hard"), self._move)
        r.on(("docker", "compose", "up"), self._build)
        r.on(("docker", "compose", "ps"), self._ps)
        r.on(("docker", "compose", "exec"), self._switchover)
        runner.on_http("GET", "http://127.0.0.1:8000/health", lambda b: (200, {"status": "ok"}) if self.healthy else (0, {}))
        for name, ip in cfg.peers.items():
            runner.on_http("GET", f"http://{ip}:8000/health", (200, {"status": "ok"}))
            runner.on_http("GET", f"http://{ip}:8008/cluster", lambda b: (200, self._members()))
        self.switchover_works = True

    def _move(self, args):
        self.head = args[-1]
        return Result(0, "")

    def _build(self, args):
        code = self.builds.pop(0) if self.builds else 0
        if code == 0:
            self.healthy = self.healthy_after_build if self.head != OLD else True
        return Result(code, "" if code == 0 else "step 3/9 failed\nERROR: build broke")

    def _ps(self, args):
        names = EXPECTED_TRIPLE if self.cfg.triple else EXPECTED_SINGLE
        rows = [{"Service": s, "State": "running", "Health": "healthy" if self.healthy else "starting"} for s in names]
        return Result(0, "\n".join(json.dumps(x) for x in rows))

    def _members(self):
        names = ["processing", "web", "ai"]
        return {"members": [{"name": n, "role": "leader" if n == self.leader else
                             ("sync_standby" if n == "ai" else "replica"),
                             "state": "running" if n == self.leader else "streaming"} for n in names]}

    def _switchover(self, args):
        if self.switchover_works:
            self.leader = args[args.index("--candidate") + 1]
        return Result(0, "")
