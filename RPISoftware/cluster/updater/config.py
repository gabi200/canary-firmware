"""This Pi's settings, read from RPISoftware/.env (written by scripts/pi_setup.sh)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

DEFAULT_PORT = 8010


@dataclass(frozen=True)
class Config:
    repo: Path  # the git checkout's root
    app_dir: Path  # RPISoftware: docker-compose.yml and .env
    node: str  # processing | web | ai, or "hub" on a one-Pi hub
    triple: bool
    node_ip: str
    peers: dict[str, str]  # every Pi (this one included) -> its LAN address
    key: str
    port: int
    state_file: Path


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def load_config(app_dir: Path, repo: Path, state_file: Path) -> Config:
    env = read_env(app_dir / ".env")
    triple = env.get("CANARY_CLUSTER_MODE") == "triple"
    if triple:
        node, node_ip = env.get("CANARY_NODE_NAME", ""), env.get("CANARY_NODE_IP", "")
        peers = {"processing": env.get("CANARY_PROCESSING_IP", ""), "web": env.get("CANARY_WEB_IP", ""),
                 "ai": env.get("CANARY_AI_IP", "")}
    else:
        node, node_ip, peers = "hub", "127.0.0.1", {"hub": "127.0.0.1"}
    port = env.get("CANARY_UPDATER_PORT", "")
    return Config(repo=repo, app_dir=app_dir, node=node, triple=triple, node_ip=node_ip, peers=peers,
                  key=env.get("CANARY_UPDATER_KEY", ""), port=int(port) if port.isdigit() else DEFAULT_PORT,
                  state_file=state_file)
