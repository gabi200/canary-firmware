"""Announces the hub on the LAN as canary-hub.local and _canary-hub._tcp.

Runs on every Pi (compose service "announcer"). On a three-Pi hub only the Pi that holds the
floating IP (keepalived's vrrp_state is MASTER) announces, and only while its etcd has quorum, so a
Pi cut off from the others stays silent. The announced address is the one on the default route
(the hotspot's DHCP address), never a fixed cluster address: sensors and phones live on the
hotspot's subnet and cannot reach the cluster range. Publishing goes through the host's
avahi-daemon (avahi-publish over the mounted D-Bus socket).
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request
from typing import Callable, Protocol

HUB_NAME = "canary-hub.local"
SERVICE_TYPE = "_canary-hub._tcp"
SERVICE_NAME = "Canary hub"
API_PORT = 8000
LOOP_S = 2.0
VRRP_STATE_FILE = "/run/canary/vrrp_state"
ETCD_HEALTH_URL = "http://127.0.0.1:2379/health"


class Proc(Protocol):
    def poll(self) -> int | None: ...
    def terminate(self) -> None: ...


def log(msg: str) -> None:
    print(f"[announcer] {msg}", flush=True)


def should_announce(enabled: bool, cluster_mode: str, vrrp_state: str | None, etcd_healthy: bool) -> bool:
    if not enabled:  # CANARY_ANNOUNCE=1 only on Pis (scripts/pi_setup.sh), never a dev laptop
        return False
    if cluster_mode != "triple":
        return True
    return vrrp_state == "MASTER" and etcd_healthy


def routable_ipv4(route_get_output: str, cluster_ips: set[str]) -> str | None:
    match = re.search(r"\bsrc (\d+\.\d+\.\d+\.\d+)", route_get_output)
    if match is None or match.group(1) in cluster_ips:
        return None
    return match.group(1)


def publish_commands(address: str, node: str) -> list[list[str]]:
    return [
        ["avahi-publish", "-a", "-R", HUB_NAME, address],
        ["avahi-publish", "-s", SERVICE_NAME, SERVICE_TYPE, str(API_PORT),
         f"api=http://{address}:{API_PORT}", f"node={node}"],
    ]


class Publisher:
    """Keeps one avahi-publish process per command alive for the current target."""

    def __init__(self, spawn: Callable[[list[str]], Proc]):
        self._spawn = spawn
        self._target: tuple[str, str] | None = None
        self._procs: list[Proc | None] = []

    def apply(self, target: tuple[str, str] | None) -> None:
        if target != self._target:
            self._withdraw()
            self._target = target
            if target is not None:
                log(f"announcing {HUB_NAME} -> {target[0]} (node {target[1]})")
        if self._target is None:
            return
        commands = publish_commands(*self._target)
        if not self._procs:
            self._procs = [None] * len(commands)
        for i, cmd in enumerate(commands):
            proc = self._procs[i]
            if proc is not None and proc.poll() is None:
                continue
            if proc is not None:
                # avahi refuses a name another Pi still holds (failover overlap): retry.
                log(f"{cmd[1]} publisher exited ({proc.poll()}), restarting")
            try:
                self._procs[i] = self._spawn(cmd)
            except OSError as exc:
                self._procs[i] = None
                log(f"cannot start {cmd[0]}: {exc}")

    def _withdraw(self) -> None:
        if self._target is not None:
            log(f"withdrawing {HUB_NAME} ({self._target[0]})")
        for proc in self._procs:
            if proc is not None and proc.poll() is None:
                proc.terminate()
        self._procs = []


def _read_vrrp_state() -> str | None:
    try:
        with open(VRRP_STATE_FILE, encoding="ascii") as f:
            return f.read().strip() or None
    except OSError:
        return None


def _etcd_healthy() -> bool:
    try:
        with urllib.request.urlopen(ETCD_HEALTH_URL, timeout=1) as resp:
            return json.load(resp).get("health") == "true"
    except (OSError, ValueError):
        return False


def _route_get() -> str:
    try:
        return subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], capture_output=True,
                              text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


class AvahiProc:
    """An avahi-publish process. When another machine already holds the name, avahi-publish
    does not exit: it renames itself ("canary-hub-2.local") and keeps running, and sensors
    would never find the hub. poll() treats that rename as an exit (after stopping the
    process), so the Publisher publishes the real name again on a later loop."""

    def __init__(self, cmd: list[str]):
        self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert self._proc.stdout is not None
        os.set_blocking(self._proc.stdout.fileno(), False)
        self._output = b""
        self._collided = False

    def poll(self) -> int | None:
        if not self._collided:
            try:
                chunk = self._proc.stdout.read() if self._proc.stdout else None
            except OSError:
                chunk = None
            if chunk:
                self._output = (self._output + chunk)[-4096:]
                if b"Name collision" in self._output:
                    self._collided = True
                    log(f"name collision ({self._output.decode(errors='replace').strip().splitlines()[-1]}), will retry")
                    self.terminate()
        code = self._proc.poll()
        if self._collided:
            return code if code is not None else 1
        return code

    def terminate(self) -> None:
        if self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self._proc.kill()


def _spawn(cmd: list[str]) -> Proc:
    return AvahiProc(cmd)


def main() -> None:
    enabled = os.environ.get("CANARY_ANNOUNCE", "") == "1"
    mode = os.environ.get("CANARY_CLUSTER_MODE", "")
    node = os.environ.get("CANARY_NODE_NAME") or "hub"
    cluster_ips = {ip for ip in (os.environ.get(v, "") for v in (
        "CANARY_VIP", "CANARY_PROCESSING_IP", "CANARY_WEB_IP", "CANARY_AI_IP")) if ip}
    publisher = Publisher(_spawn)

    def stop(*_: object) -> None:
        publisher.apply(None)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"started: mode={mode or 'single'} node={node}"
        + ("" if enabled else " (CANARY_ANNOUNCE is not 1: not announcing; scripts/pi_setup.sh sets it)"))
    while True:
        state = _read_vrrp_state() if mode == "triple" else None
        healthy = _etcd_healthy() if mode == "triple" else True
        address = routable_ipv4(_route_get(), cluster_ips)
        wanted = should_announce(enabled, mode, state, healthy) and address is not None
        publisher.apply((address, node) if wanted and address else None)
        time.sleep(LOOP_S)


if __name__ == "__main__":
    main()
