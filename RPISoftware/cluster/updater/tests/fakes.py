"""A scripted Runner: commands and HTTP calls answer from tables, sleep moves a fake clock."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

from updater.runner import Result, Runner


class FakeRunner(Runner):
    def __init__(self) -> None:
        self._runs: list[tuple[tuple[str, ...], Result | Callable[[list[str]], Result]]] = []
        self._http: dict[tuple[str, str], tuple[int, dict] | Callable[[dict | None], tuple[int, dict]]] = {}
        self.calls: list[list[str]] = []
        self.http_calls: list[tuple[str, str, dict | None]] = []
        self.clock = 0.0

    def on(self, prefix: tuple[str, ...], result: Result | Callable[[list[str]], Result]) -> None:
        self._runs.append((prefix, result))

    def on_http(self, method: str, url: str, reply) -> None:
        self._http[(method, url)] = reply

    def run(self, args: list[str], *, cwd: Path, timeout: float) -> Result:
        self.calls.append(list(args))
        best = None
        for prefix, result in self._runs:
            if tuple(args[: len(prefix)]) == prefix and (best is None or len(prefix) >= len(best[0])):
                best = (prefix, result)
        if best is None:
            return Result(0, "")
        result = best[1]
        return result(list(args)) if callable(result) else result

    def http(self, method, url, *, body=None, headers=None, timeout=3.0):
        self.http_calls.append((method, url, body))
        reply = self._http.get((method, url))
        if reply is None:
            return 0, {}
        return reply(body) if callable(reply) else reply

    def sleep(self, s: float) -> None:
        self.clock += s

    def now(self) -> float:
        return self.clock

    def ran(self, *prefix: str) -> bool:
        return any(tuple(c[: len(prefix)]) == prefix for c in self.calls)

    def index(self, *prefix: str) -> int:
        return next(i for i, c in enumerate(self.calls) if tuple(c[: len(prefix)]) == prefix)
