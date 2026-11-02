"""The git side: where this checkout is, what origin/main has, and moving between commits."""

from __future__ import annotations

import re
from pathlib import Path

from updater.runner import Result, Runner

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
REMOTE = "origin/main"
SEP = "\x1f"


def _git(r: Runner, repo: Path, *args: str, timeout: float = 30) -> Result:
    return r.run(["git", *args], cwd=repo, timeout=timeout)


def head(r: Runner, repo: Path, ref: str = "HEAD") -> dict | None:
    res = _git(r, repo, "log", "-1", f"--format=%H{SEP}%s{SEP}%cI", ref)
    parts = res.out.strip().split(SEP)
    if res.code != 0 or len(parts) != 3:
        return None
    return {"sha": parts[0], "subject": parts[1], "date": parts[2]}


def branch(r: Runner, repo: Path) -> str:
    return _git(r, repo, "rev-parse", "--abbrev-ref", "HEAD").out.strip()


def dirty(r: Runner, repo: Path) -> bool:
    return bool(_git(r, repo, "status", "--porcelain", "--untracked-files=no").out.strip())


def counts(r: Runner, repo: Path) -> tuple[int, int]:
    """(behind, ahead) of origin/main; (0, 0) if git cannot tell (never fetched)."""
    parts = _git(r, repo, "rev-list", "--left-right", "--count", f"{REMOTE}...HEAD").out.split()
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        return 0, 0
    return int(parts[0]), int(parts[1])


def incoming(r: Runner, repo: Path, limit: int = 30) -> list[dict]:
    res = _git(r, repo, "log", f"HEAD..{REMOTE}", "-n", str(limit), f"--format=%H{SEP}%s{SEP}%an{SEP}%cI")
    commits = []
    for line in res.out.splitlines() if res.code == 0 else []:
        parts = line.split(SEP)
        if len(parts) == 4:
            commits.append({"sha": parts[0], "subject": parts[1], "author": parts[2], "date": parts[3]})
    return commits


def fetch(r: Runner, repo: Path) -> Result:
    return _git(r, repo, "fetch", "--quiet", "origin", "main", timeout=25)  # the dashboard waits for it


def on_main(r: Runner, repo: Path, sha: str) -> bool:
    return _git(r, repo, "merge-base", "--is-ancestor", sha, REMOTE).code == 0


def ff_merge(r: Runner, repo: Path, sha: str) -> Result:
    return _git(r, repo, "merge", "--ff-only", sha, timeout=120)


def reset_hard(r: Runner, repo: Path, sha: str) -> Result:
    return _git(r, repo, "reset", "--hard", sha, timeout=120)


def changed(r: Runner, repo: Path, a: str, b: str, path: str) -> bool:
    return bool(_git(r, repo, "diff", "--name-only", a, b, "--", path).out.strip())
