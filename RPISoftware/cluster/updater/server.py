"""The helper's HTTP API (port 8010). Every request needs the key from .env; without it the
answer is a bare 404, as if nothing listened here. One job (an update or a rollout) at a time."""

from __future__ import annotations

import hmac
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

from updater import gitops, health
from updater.config import Config
from updater.pi import PiUpdater, Refused
from updater.rollout import KEY_HEADER, Rollout

BUSY_MSG = "an update is already running on this Pi"
MAX_BODY = 4096


def make_server(cfg: Config, local: PiUpdater, rollout: Rollout, host: str, port: int,
                exit_fn: Callable[[int], object] = os._exit) -> ThreadingHTTPServer:
    job = threading.Lock()

    def start(begin: Callable[[], None], work: Callable[[], None]) -> tuple[int, dict]:
        if not job.acquire(blocking=False):
            return 409, {"error": BUSY_MSG}
        try:
            begin()
        except Refused as exc:
            job.release()
            return 409, {"error": str(exc)}
        except Exception:
            job.release()
            raise

        def body() -> None:
            try:
                work()
            except Exception as exc:  # noqa: BLE001 - never leave the Pi "updating" with nobody told
                local.fail(f"the updater hit an unexpected error: {exc!r}")
            finally:
                job.release()
            if local.state()["restart_needed"]:
                local.update_state(restart_needed=False)
                exit_fn(0)  # systemd starts the new version of this helper

        threading.Thread(target=body, daemon=True).start()
        return 202, local.status()

    class Handler(BaseHTTPRequestHandler):
        server_version = "canary-updater"

        def log_message(self, fmt, *args):  # journald gets the job log instead
            pass

        def _send(self, status: int, body: dict | None) -> None:
            raw = json.dumps(body).encode() if body is not None else b""
            self.send_response(status)
            if body is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _authorized(self) -> bool:
            key = self.headers.get(KEY_HEADER) or ""
            return bool(cfg.key) and hmac.compare_digest(key.encode(), cfg.key.encode())

        def _commit(self) -> str | None:
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_BODY:
                return None
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                return None
            sha = body.get("commit") if isinstance(body, dict) else None
            return sha if isinstance(sha, str) and gitops.SHA_RE.match(sha) else None

        def do_GET(self) -> None:
            if not self._authorized():
                return self._send(404, None)
            if self.path == "/status":
                return self._send(200, local.status())
            if self.path == "/health":
                return self._send(200, {"problem": health.problem(cfg, local.r)})
            if self.path == "/incoming":
                return self._send(200, {"head": gitops.head(local.r, cfg.repo, gitops.REMOTE),
                                        "commits": gitops.incoming(local.r, cfg.repo)})
            self._send(404, None)

        def do_POST(self) -> None:
            if not self._authorized():
                return self._send(404, None)
            if self.path == "/fetch":
                local.fetch()
                return self._send(200, local.status())
            if self.path == "/dismiss":
                local.dismiss()
                return self._send(200, local.status())
            if self.path == "/check":
                sha = self._commit()
                if sha is None:
                    return self._send(422, {"error": "commit must be a 40-character hex id"})
                if job.locked():
                    return self._send(409, {"error": BUSY_MSG})
                try:
                    local.check(sha)
                except Refused as exc:
                    return self._send(409, {"error": str(exc)})
                return self._send(200, {})
            if self.path in ("/update", "/rollout"):
                sha = self._commit()
                if sha is None:
                    return self._send(422, {"error": "commit must be a 40-character hex id"})
                if self.path == "/update":
                    return self._send(*start(lambda: local.begin(sha), local.run))
                return self._send(*start(lambda: rollout.begin(sha), rollout.run))
            self._send(404, None)

    return ThreadingHTTPServer((host, port), Handler)
