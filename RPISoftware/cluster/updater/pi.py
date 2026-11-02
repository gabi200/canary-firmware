"""Updating this Pi to one commit: database off it first, fast-forward, rebuild, wait for healthy,
and back to the previous commit if any of that fails."""

from __future__ import annotations

import threading
from datetime import datetime, timezone

from updater import gitops, health
from updater.config import Config
from updater.runner import Result, Runner
from updater.store import StateStore

BUILD_TIMEOUT_S = 1800
HEALTH_TIMEOUT_S = 300
POLL_S = 5
LOG_LINES = 50
SWITCHOVER_TIMEOUT_S = 60
BUSY = ("updating", "rolling_back")
SELF_PATH = "RPISoftware/cluster/updater"


class Refused(Exception):
    """An update that must not start; the message is shown to the user."""


class _Step(Exception):
    """A failed step of an update; the message becomes the Pi's error."""


def _utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _last_line(res: Result) -> str:
    lines = [line for line in res.out.strip().splitlines() if line.strip()]
    return lines[-1].strip() if lines else f"exit code {res.code}"


class PiUpdater:
    def __init__(self, cfg: Config, r: Runner, store: StateStore) -> None:
        self.cfg, self.r, self.store = cfg, r, store
        self.lock = threading.RLock()

    # ------------------------------------------------------------------ state
    def state(self) -> dict:
        with self.lock:
            return {"state": "idle", "step": None, "target": None, "previous": None, "error": None, "log": [],
                    "rollout": None, "restart_needed": False, "fetched_at": None, "fetch_error": None,
                    **self.store.load()}

    def update_state(self, **changes) -> None:
        with self.lock:
            current = self.store.load()
            current.update(changes)
            self.store.save(current)

    def _log(self, line: str, step: str | None = None) -> None:
        with self.lock:
            current = self.state()
            log = (current["log"] + [f"{_utc()} {line}"])[-LOG_LINES:]
            self.update_state(log=log, **({"step": step} if step else {}))

    def status(self) -> dict:
        repo = self.cfg.repo
        behind, ahead = gitops.counts(self.r, repo)
        return {"node": self.cfg.node, "commit": gitops.head(self.r, repo), "branch": gitops.branch(self.r, repo),
                "dirty": gitops.dirty(self.r, repo), "behind": behind, "ahead": ahead, **self.state()}

    # ------------------------------------------------------------------ actions
    def recover(self) -> None:
        if self.state()["state"] in BUSY:
            self.update_state(state="failed",
                              error="the updater stopped during the update (power cut or crash): check this Pi")

    def fetch(self) -> None:
        res = gitops.fetch(self.r, self.cfg.repo)
        if res.code == 0:
            self.update_state(fetched_at=_utc(), fetch_error=None)
        else:
            self.update_state(fetch_error=_last_line(res))

    def dismiss(self) -> None:
        with self.lock:
            if self.state()["state"] in ("rolled_back", "failed"):
                self.update_state(state="idle", error=None)

    def preflight(self, sha: str, check_peers: bool = True) -> None:
        repo = self.cfg.repo
        if self.state()["state"] in BUSY:
            raise Refused("an update is already running on this Pi")
        if gitops.branch(self.r, repo) != "main":
            raise Refused("not on branch main")
        if gitops.dirty(self.r, repo):
            raise Refused("this Pi has local changes")
        if not gitops.on_main(self.r, repo, sha):
            raise Refused("unknown commit: fetch first")
        if self.cfg.triple and check_peers:
            for name in self.cfg.peers:
                if name != self.cfg.node and (problem := health.peer_problem(self.cfg, self.r, name)):
                    raise Refused(problem)

    def begin(self, sha: str, check_peers: bool = True) -> None:
        with self.lock:
            self.preflight(sha, check_peers)
            current = gitops.head(self.r, self.cfg.repo)
            self.update_state(state="updating", target=sha, previous=current["sha"] if current else None,
                              error=None, log=[], step="starting", restart_needed=False)

    def run(self) -> None:
        s = self.state()
        target, previous = s["target"], s["previous"]
        try:
            self._move_database_off()
        except _Step as exc:
            self._log(str(exc))
            self.update_state(state="idle", step="stopped", error=str(exc))
            return
        try:
            self._log(f"fast-forward to {target[:7]}", "pulling")
            res = gitops.ff_merge(self.r, self.cfg.repo, target)
            if res.code != 0:
                raise _Step(f"git: {_last_line(res)}")
            self._build_and_wait()
        except _Step as exc:
            self._rollback(previous, str(exc))
            return
        changed = bool(previous) and gitops.changed(self.r, self.cfg.repo, previous, target, SELF_PATH)
        self._log("healthy on the new commit", "done")
        self.update_state(state="idle", step="done", restart_needed=changed)

    # ------------------------------------------------------------------ steps
    def _build_and_wait(self) -> None:
        self._log("docker compose up -d --build", "building")
        res = self.r.run(["docker", "compose", "up", "-d", "--build"], cwd=self.cfg.app_dir, timeout=BUILD_TIMEOUT_S)
        if res.code != 0:
            raise _Step(f"build failed: {_last_line(res)}")
        self._log("waiting until healthy", "checking")
        deadline = self.r.now() + HEALTH_TIMEOUT_S
        while (problem := health.problem(self.cfg, self.r)) is not None:
            if self.r.now() >= deadline:
                raise _Step(f"not healthy after {HEALTH_TIMEOUT_S // 60} min: {problem}")
            self.r.sleep(POLL_S)

    def _rollback(self, previous: str | None, error: str) -> None:
        self._log(f"failed: {error}; rolling back", "rolling back")
        self.update_state(state="rolling_back", error=error)
        try:
            if not previous:
                raise _Step("no previous commit recorded")
            res = gitops.reset_hard(self.r, self.cfg.repo, previous)
            if res.code != 0:
                raise _Step(f"git: {_last_line(res)}")
            self._build_and_wait()
        except _Step as exc:
            self._log(f"rollback failed: {exc}", "failed")
            self.update_state(state="failed", error=f"{error}; rollback also failed: {exc}")
            return
        self._log(f"back on {previous[:7]}", "rolled back")
        self.update_state(state="rolled_back")

    def _move_database_off(self) -> None:
        """Three Pis: if this Pi's Postgres leads, hand leadership to a healthy replica first."""
        if not self.cfg.triple:
            return
        members = health.patroni_members(self.cfg, self.r) or []
        if not any(m.get("name") == self.cfg.node and m.get("role") == "leader" for m in members):
            return
        others = [m for m in members if m.get("name") != self.cfg.node and m.get("state") in ("running", "streaming")]
        others.sort(key=lambda m: m.get("role") != "sync_standby")
        if not others:
            raise _Step("could not move the database off this Pi: no healthy replica")
        candidate = others[0]["name"]
        self._log(f"moving the database leader to the {candidate} Pi", "moving database")
        res = self.r.run(["docker", "compose", "exec", "-T", "postgres", "patronictl", "switchover",
                          "--leader", self.cfg.node, "--candidate", candidate, "--force"],
                         cwd=self.cfg.app_dir, timeout=120)
        deadline = self.r.now() + SWITCHOVER_TIMEOUT_S
        while True:
            members = health.patroni_members(self.cfg, self.r) or []
            if any(m.get("role") == "leader" and m.get("name") != self.cfg.node for m in members):
                return
            if self.r.now() >= deadline:
                why = _last_line(res) if res.code != 0 else f"the leader did not change within {SWITCHOVER_TIMEOUT_S} s"
                raise _Step(f"could not move the database off this Pi: {why}")
            self.r.sleep(POLL_S)
