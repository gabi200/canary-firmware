"""python3 -m updater (from RPISoftware/cluster): the canary-updater service (canary-updater.service)."""

from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

from updater.config import load_config
from updater.pi import BUSY, PiUpdater
from updater.rollout import Rollout
from updater.runner import Runner
from updater.server import make_server
from updater.store import StateStore

FETCH_EVERY_S = 900


def main() -> int:
    app_dir = Path(__file__).resolve().parents[2]
    runner = Runner()
    top = runner.run(["git", "rev-parse", "--show-toplevel"], cwd=app_dir, timeout=10)
    if top.code != 0:
        print(f"canary-updater: {app_dir} is not inside a git checkout", file=sys.stderr)
        return 1
    state_file = Path.home() / ".local" / "state" / "canary-updater" / "state.json"
    cfg = load_config(app_dir, Path(top.out.strip()), state_file)
    if not cfg.key:
        print("CANARY_UPDATER_KEY is missing in .env: run scripts/pi_setup.sh", file=sys.stderr)
        return 1
    if cfg.triple and (cfg.node not in cfg.peers or not cfg.node_ip):
        print("CANARY_NODE_NAME / CANARY_NODE_IP missing in .env: run scripts/pi_setup.sh", file=sys.stderr)
        return 1
    local = PiUpdater(cfg, runner, StateStore(state_file))
    local.recover()

    def fetch_loop() -> None:
        while True:
            if local.state()["state"] not in BUSY:
                local.fetch()
            time.sleep(FETCH_EVERY_S)

    threading.Thread(target=fetch_loop, daemon=True).start()
    host = cfg.node_ip if cfg.triple else "0.0.0.0"
    server = make_server(cfg, local, Rollout(cfg, runner, local), host, cfg.port)
    print(f"canary-updater: {cfg.node} on {host}:{cfg.port}, checkout {cfg.repo}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
