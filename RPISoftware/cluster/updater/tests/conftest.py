from pathlib import Path

import pytest

from updater.config import Config
from updater.tests.fakes import FakeRunner

PEERS = {"processing": "10.0.0.11", "web": "10.0.0.12", "ai": "10.0.0.13"}


def make_cfg(tmp_path: Path, node: str = "web", triple: bool = True) -> Config:
    return Config(repo=tmp_path, app_dir=tmp_path / "RPISoftware", node=node if triple else "hub", triple=triple,
                  node_ip=PEERS[node] if triple else "127.0.0.1", peers=dict(PEERS) if triple else {"hub": "127.0.0.1"},
                  key="k", port=8010, state_file=tmp_path / "state.json")


@pytest.fixture
def runner() -> FakeRunner:
    return FakeRunner()
