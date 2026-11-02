"""Everything the helper does to the outside world, behind one object the tests replace."""

from __future__ import annotations

import json
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Result:
    code: int
    out: str


class Runner:
    def run(self, args: list[str], *, cwd: Path, timeout: float) -> Result:
        try:
            done = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return Result(124, "timed out")
        except FileNotFoundError:
            return Result(127, f"{args[0]}: not found")
        return Result(done.returncode, (done.stdout or "") + (done.stderr or ""))

    def http(self, method: str, url: str, *, body: dict | None = None,
             headers: dict[str, str] | None = None, timeout: float = 3.0) -> tuple[int, dict]:
        """(status, JSON object); status 0 and {} when the other side cannot be reached."""
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={**(headers or {}),
                                     **({"Content-Type": "application/json"} if data is not None else {})})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, raw = err.code, err.read()
        except (OSError, ValueError):
            return 0, {}
        try:
            parsed = json.loads(raw) if raw else {}
        except ValueError:
            parsed = {}
        return status, parsed if isinstance(parsed, dict) else {}

    def sleep(self, s: float) -> None:
        time.sleep(s)

    def now(self) -> float:
        return time.monotonic()
