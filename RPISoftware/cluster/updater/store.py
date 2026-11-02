"""The helper's state on disk, so a restart (or its own update) does not forget an outcome."""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def save(self, state: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=".state-")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        os.replace(tmp, self.path)
