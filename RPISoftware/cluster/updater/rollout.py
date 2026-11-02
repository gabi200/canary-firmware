"""Updating every Pi, one at a time: each must be healthy on the new commit before the next starts,
the Postgres leader goes last, and the first Pi that does not make it stops the rollout."""

from __future__ import annotations

from updater import gitops, health
from updater.config import Config
from updater.pi import BUSY, PiUpdater, Refused, _utc
from updater.runner import Runner

PI_TIMEOUT_S = 3600
POLL_S = 3
ORDER = ("ai", "processing", "web")
KEY_HEADER = "X-Canary-Updater-Key"


class Rollout:
    def __init__(self, cfg: Config, r: Runner, local: PiUpdater) -> None:
        self.cfg, self.r, self.local = cfg, r, local

    def _url(self, name: str, path: str) -> str:
        return f"http://{self.cfg.peers[name]}:{self.cfg.port}{path}"

    def _call(self, method: str, name: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        return self.r.http(method, self._url(name, path), body=body, headers={KEY_HEADER: self.cfg.key}, timeout=5)

    def order(self) -> list[str]:
        if not self.cfg.triple:
            return [self.cfg.node]
        members = health.patroni_members(self.cfg, self.r) or []
        leader = next((m.get("name") for m in members if m.get("role") == "leader"), None)
        return [n for n in ORDER if n != leader] + ([leader] if leader in ORDER else [])

    def begin(self, sha: str) -> None:
        if (self.local.state().get("rollout") or {}).get("outcome") == "running":
            raise Refused("an update is already running on this Pi")
        for name in self.cfg.peers:
            if name == self.cfg.node:
                continue
            status, st = self._call("GET", name, "/status")
            if status != 200:
                raise Refused(f"the {name} Pi's updater does not answer")
            if st.get("state") in BUSY:
                raise Refused(f"an update is already running on the {name} Pi")
            if st.get("state") == "failed":
                raise Refused(f"the {name} Pi's last update failed: check it first")
            if st.get("branch") != "main":
                raise Refused(f"the {name} Pi is not on branch main")
            if st.get("dirty"):
                raise Refused(f"the {name} Pi has local changes")
        self.local.preflight(sha, check_peers=True)
        order = self.order()
        self.local.update_state(rollout={"commit": sha, "order": order, "results": {n: "waiting" for n in order},
                                         "current": None, "outcome": "running", "reason": None,
                                         "started_at": _utc()})

    def _set(self, **changes) -> None:
        with self.local.lock:
            rollout = dict(self.local.state()["rollout"])
            results = dict(rollout["results"])
            if "result" in changes:
                name, result = changes.pop("result")
                results[name] = result
            rollout.update(changes, results=results)
            self.local.update_state(rollout=rollout)

    def run(self) -> None:
        sha = self.local.state()["rollout"]["commit"]
        for name in self.local.state()["rollout"]["order"]:
            self._set(current=name, result=(name, "updating"))
            result, error = self._update_self(sha) if name == self.cfg.node else self._update_peer(name, sha)
            self._set(result=(name, result))
            if result != "done":
                self._set(current=None, outcome="stopped", reason=f"{name} Pi: {error}")
                return
        self._set(current=None, outcome="done")

    def _update_self(self, sha: str) -> tuple[str, str | None]:
        try:
            self.local.begin(sha, check_peers=False)
        except Refused as exc:
            return "failed", str(exc)
        self.local.run()
        st = self.local.state()
        head = gitops.head(self.r, self.cfg.repo)
        if st["state"] == "idle" and head and head["sha"] == sha:
            return "done", None
        return (st["state"] if st["state"] in ("rolled_back", "failed") else "failed"), st["error"] or "update stopped"

    def _update_peer(self, name: str, sha: str) -> tuple[str, str | None]:
        status, body = self._call("POST", name, "/update", {"commit": sha})
        if status != 202:
            return "failed", body.get("error") or f"its updater answered {status or 'nothing'}"
        deadline = self.r.now() + PI_TIMEOUT_S
        while True:
            self.r.sleep(POLL_S)
            status, st = self._call("GET", name, "/status")
            if status == 200 and st.get("state") not in BUSY and st.get("target") == sha:
                if st.get("state") == "idle" and (st.get("commit") or {}).get("sha") == sha:
                    return "done", None
                state = st.get("state")
                return (state if state in ("rolled_back", "failed") else "failed"), st.get("error") or "update stopped"
            if self.r.now() >= deadline:
                return "failed", f"no result after {PI_TIMEOUT_S // 60} min"
