"""Tests for the broker relay's decisions (no broker, no aiomqtt)."""

import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pytest  # noqa: E402

from relay import goes_down, goes_up, holds_address, keep_retained  # noqa: E402


@pytest.mark.parametrize(
    "topic",
    [
        "canary/status",
        "canary_black/availability",
        "water-kitchen/command/result",
        "espectre/v1/devices/bedroom/motion",
        "canary/v1/site/zone/telemetry",
    ],
)
def test_live_device_messages_go_up(topic):
    assert goes_up(topic, retained=False, relayed=False) is True


def test_a_retained_delivery_never_goes_up():
    """The stale-document guard: a stored message must not reach the hub looking live."""
    assert goes_up("water_sensor/status", retained=True, relayed=False) is False


def test_a_relayed_message_never_goes_up_again():
    """The loop guard: two relays that both think they are off the VIP must not ping-pong."""
    assert goes_up("canary/status", retained=False, relayed=True) is False


@pytest.mark.parametrize("topic", ["canary/buzzer/set", "water-kitchen/valve/set"])
def test_commands_do_not_go_up(topic):
    assert goes_up(topic, retained=False, relayed=False) is False


@pytest.mark.parametrize("topic", ["canary/buzzer/set", "water-kitchen/valve/set"])
def test_live_commands_go_down(topic):
    assert goes_down(topic, retained=False, relayed=False) is True


@pytest.mark.parametrize(
    "topic", ["canary/status", "canary/availability", "canary/command/result"]
)
def test_device_messages_do_not_come_back_down(topic):
    assert goes_down(topic, retained=False, relayed=False) is False


def test_a_retained_command_does_not_go_down():
    """A stored valve command must not fire when the relay reconnects."""
    assert goes_down("water-kitchen/valve/set", retained=True, relayed=False) is False


def test_a_relayed_command_does_not_go_down_again():
    assert goes_down("canary/buzzer/set", retained=False, relayed=True) is False


@pytest.mark.parametrize(
    "topic, retained",
    [
        # What the firmware publishes retained, so the VIP broker's copy stays current.
        ("canary/status", True),
        ("canary/availability", True),
        ("espectre/v1/devices/bedroom/health", True),
        ("espectre/v1/devices/bedroom/sensing", True),
        ("espectre/v1/devices/bedroom/device", True),
        # Never retained by the firmware: a stored copy would be read as stale.
        ("canary/command/result", False),
        ("espectre/v1/devices/bedroom/motion", False),
        ("canary/v1/site/zone/telemetry", False),
    ],
)
def test_keep_retained_matches_what_the_device_retains(topic, retained):
    assert keep_retained(topic) is retained


def test_holds_an_address_of_this_machine():
    assert holds_address("127.0.0.1") is True


def test_does_not_hold_an_address_of_another_machine():
    # TEST-NET-3 (RFC 5737): assigned to no machine.
    assert holds_address("203.0.113.7") is False


def test_a_bound_socket_on_the_address_does_not_hide_it():
    """The check must not fail just because something already listens on the VIP."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        assert holds_address("127.0.0.1") is True
