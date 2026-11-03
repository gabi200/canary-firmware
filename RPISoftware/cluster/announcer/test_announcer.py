"""Tests for the hub announcer's decisions (no avahi, no network)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import time  # noqa: E402

import socket  # noqa: E402
import struct  # noqa: E402

from announcer import (  # noqa: E402
    AvahiProc,
    Publisher,
    a_record_answer,
    asks_for_hub,
    publish_commands,
    routable_ipv4,
    should_announce,
)


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
    assert should_announce(True, "", None, False)  # one Pi: always
    assert should_announce(True, "triple", "MASTER", True)
    assert not should_announce(True, "triple", "MASTER", False)  # no quorum: stay silent
    assert not should_announce(True, "triple", "BACKUP", True)
    assert not should_announce(True, "triple", None, True)


def test_not_enabled_never_announces():
    # A developer laptop running the stack must not take canary-hub.local from the real hub:
    # only Pis set up by scripts/pi_setup.sh (CANARY_ANNOUNCE=1) announce.
    assert not should_announce(False, "", None, True)
    assert not should_announce(False, "triple", "MASTER", True)


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


def _poll_until_exit(proc, seconds=3.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        code = proc.poll()
        if code is not None:
            return code
        time.sleep(0.05)
    return None


def test_renamed_publisher_counts_as_exited():
    # avahi-publish does not exit when another machine holds the name: it renames itself
    # ("canary-hub-2.local") and keeps running. That must be treated as a failed publish.
    proc = AvahiProc(["sh", "-c", "echo \"Name collision, picking new name 'canary-hub-2.local'.\" >&2; sleep 30"])
    try:
        assert _poll_until_exit(proc) is not None
    finally:
        proc.terminate()


def test_healthy_publisher_keeps_running():
    proc = AvahiProc(["sh", "-c", "echo \"Established under name 'canary-hub.local'\"; sleep 30"])
    try:
        time.sleep(0.3)
        assert proc.poll() is None
    finally:
        proc.terminate()


def _query(name: str, qtype: int = 1, flags: int = 0, qclass: int = 1) -> bytes:
    labels = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return struct.pack(">HHHHHH", 0, flags, 1, 0, 0, 0) + labels + struct.pack(">HH", qtype, qclass)


def test_asks_for_hub_a_and_any_questions():
    assert asks_for_hub(_query("canary-hub.local"))
    assert asks_for_hub(_query("Canary-Hub.LOCAL"))
    assert asks_for_hub(_query("canary-hub.local", qtype=255))
    assert asks_for_hub(_query("canary-hub.local", qclass=0x8001))  # unicast-response bit


def test_asks_for_hub_ignores_other_questions_and_answers():
    assert not asks_for_hub(_query("canary3.local"))
    assert not asks_for_hub(_query("canary-hub.local", qtype=28))  # AAAA
    assert not asks_for_hub(_query("canary-hub.local", flags=0x8400))  # a response
    assert not asks_for_hub(b"")
    assert not asks_for_hub(b"\x00" * 12 + b"\x3f")  # truncated name


def test_asks_for_hub_finds_the_name_after_a_compressed_question():
    first = b"\x07_canary\x04_tcp\x05local\x00" + struct.pack(">HH", 12, 1)
    # Second question: "canary-hub" + pointer to "local" inside the first one (offset 12 + 13).
    second = b"\x0acanary-hub\xc0" + bytes([12 + 13]) + struct.pack(">HH", 1, 1)
    packet = struct.pack(">HHHHHH", 0, 0, 2, 0, 0, 0) + first + second
    assert asks_for_hub(packet)


def test_a_record_answer_is_an_authoritative_cache_flush_a_record():
    packet = a_record_answer("10.72.33.188")
    assert packet[:12] == struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0)
    assert packet[12:30] == b"\x0acanary-hub\x05local\x00"
    assert packet[30:40] == struct.pack(">HHIH", 1, 0x8001, 120, 4)
    assert packet[40:] == socket.inet_aton("10.72.33.188")
