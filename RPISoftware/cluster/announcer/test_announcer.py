"""Tests for the hub announcer's decisions (no avahi, no network)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from announcer import Publisher, publish_commands, routable_ipv4, should_announce  # noqa: E402


class FakeProc:
    def __init__(self, cmd):
        self.cmd = cmd
        self.exit_code = None
        self.terminated = False

    def poll(self):
        return self.exit_code

    def terminate(self):
        self.terminated = True


class FakeSpawn:
    def __init__(self):
        self.procs = []
        self.fail_next = False

    def __call__(self, cmd):
        if self.fail_next:
            self.fail_next = False
            raise OSError("no such file: avahi-publish")
        proc = FakeProc(cmd)
        self.procs.append(proc)
        return proc


def test_should_announce():
    assert should_announce("", None, False)  # one Pi: always
    assert should_announce("triple", "MASTER", True)
    assert not should_announce("triple", "MASTER", False)  # no quorum: stay silent
    assert not should_announce("triple", "BACKUP", True)
    assert not should_announce("triple", None, True)


def test_routable_ipv4():
    out = "1.1.1.1 via 10.247.177.226 dev wlan0 src 10.247.177.188 uid 1000\n    cache"
    assert routable_ipv4(out, set()) == "10.247.177.188"
    assert routable_ipv4(out, {"10.247.177.188"}) is None
    assert routable_ipv4("RTNETLINK answers: Network is unreachable", set()) is None


def test_publish_commands_exact():
    assert publish_commands("10.0.0.5", "web") == [
        ["avahi-publish", "-a", "-R", "canary-hub.local", "10.0.0.5"],
        ["avahi-publish", "-s", "Canary hub", "_canary-hub._tcp", "8000",
         "api=http://10.0.0.5:8000", "node=web"],
    ]


def test_apply_starts_once():
    spawn = FakeSpawn()
    pub = Publisher(spawn)
    pub.apply(("10.0.0.5", "web"))
    pub.apply(("10.0.0.5", "web"))
    assert len(spawn.procs) == 2


def test_apply_none_withdraws():
    spawn = FakeSpawn()
    pub = Publisher(spawn)
    pub.apply(("10.0.0.5", "web"))
    pub.apply(None)
    assert all(p.terminated for p in spawn.procs)
    assert len(spawn.procs) == 2


def test_address_change_republishes():
    spawn = FakeSpawn()
    pub = Publisher(spawn)
    pub.apply(("10.0.0.5", "web"))
    old = list(spawn.procs)
    pub.apply(("10.0.0.6", "web"))
    assert all(p.terminated for p in old)
    new = spawn.procs[2:]
    assert [p.cmd for p in new] == publish_commands("10.0.0.6", "web")


def test_exited_publisher_is_restarted():
    spawn = FakeSpawn()
    pub = Publisher(spawn)
    pub.apply(("10.0.0.5", "web"))
    spawn.procs[0].exit_code = 1  # avahi refused the name (another Pi still holds it)
    pub.apply(("10.0.0.5", "web"))
    assert len(spawn.procs) == 3
    assert spawn.procs[2].cmd == publish_commands("10.0.0.5", "web")[0]
    assert not spawn.procs[1].terminated


def test_spawn_failure_is_retried():
    spawn = FakeSpawn()
    spawn.fail_next = True
    pub = Publisher(spawn)
    pub.apply(("10.0.0.5", "web"))  # must not raise
    pub.apply(("10.0.0.5", "web"))
    assert sorted(p.cmd for p in spawn.procs) == sorted(publish_commands("10.0.0.5", "web"))
