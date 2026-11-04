"""Forwards live MQTT messages between this Pi's broker and the broker behind the floating IP.

Runs on every Pi of a three-Pi hub (compose service "relay"). The three brokers are separate, and
the backends only read the one behind the VIP. A sensor keeps its broker for as long as the
connection lasts, so one that connected while another Pi held the VIP goes on publishing where
nobody reads it. On a Pi without the VIP, this service copies device messages up to the VIP's broker
and commands (`<base>/.../set`) back down. On the Pi with the VIP it stays idle.

Why not a Mosquitto bridge: a bridge hands the other broker's retained messages to subscribers as
live ones (retain flag 0) on every reconnect, whatever its settings (tested on 2.1.2), and the hub
trusts live messages. An old `wet` or alarm document could raise a false incident. A subscriber
tells the two apart: a stored message arrives with the retain flag set, a live one without. So the
relay drops the former and never sees it again, and sets the flag itself where the device would.

Forwarded messages carry a user property. A relay never forwards a message that has it, so a brief
disagreement about who holds the VIP cannot start a loop. Commands and device messages also only
ever travel one way each. Messages published while a link is down are not queued: the next status
(air 15 s, water 60 s) replaces them, and a late alarm document would be worse than a missing one.

Imports aiomqtt lazily so the decisions can be tested without it. It comes from the backend image:
the Pis cannot reach PyPI on the hotspot.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
import sys

MQTT_PORT = 1883
KEEPALIVE_S = 15
HOLDER_CHECK_S = 2.0
RETRY_S = 3.0
RELAYED_PROPERTY = "canary-relay"
# What the firmware publishes with the retain flag: the air and water sensors' status and
# availability, and the ESPectre boards' health, sensing and device.
RETAINED_SUFFIXES = ("/status", "/availability", "/health", "/sensing", "/device")

log = logging.getLogger("canary.relay")


def goes_up(topic: str, *, retained: bool, relayed: bool) -> bool:
    """From this Pi's broker to the VIP's: live device messages only."""
    return not retained and not relayed and not topic.endswith("/set")


def goes_down(topic: str, *, retained: bool, relayed: bool) -> bool:
    """From the VIP's broker to this Pi's: live commands only."""
    return not retained and not relayed and topic.endswith("/set")


def keep_retained(topic: str) -> bool:
    """Whether the forwarded copy is retained: a subscriber cannot see the publisher's flag, so
    this follows what the device does. It keeps the VIP broker's stored copy current."""
    return topic.endswith(RETAINED_SUFFIXES)


def holds_address(address: str) -> bool:
    """True when this machine has the address: only then can a socket be bound to it. Needs the
    host's network (compose: network_mode host)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.bind((address, 0))
        except OSError:
            return False
    return True


def _is_relayed(message) -> bool:
    properties = message.properties
    pairs = getattr(properties, "UserProperty", None) if properties is not None else None
    return any(key == RELAYED_PROPERTY for key, _ in pairs or [])


def _marker():
    from paho.mqtt.packettypes import PacketTypes
    from paho.mqtt.properties import Properties

    properties = Properties(PacketTypes.PUBLISH)
    properties.UserProperty = (RELAYED_PROPERTY, "1")
    return properties


async def _pump(source, target, wanted, retain_for, direction: str) -> None:
    seen: set[str] = set()
    async for message in source.messages:
        topic = str(message.topic)
        if not wanted(topic, retained=bool(message.retain), relayed=_is_relayed(message)):
            continue
        if topic not in seen:
            seen.add(topic)
            log.info("forwarding %s %s", direction, topic[:120])
        await target.publish(topic, message.payload, qos=int(message.qos),
                             retain=retain_for(topic), properties=_marker())


async def _until_holding(vip: str) -> None:
    while not holds_address(vip):
        await asyncio.sleep(HOLDER_CHECK_S)


async def _relay_until_holding(vip: str, local_host: str, node: str, password: str) -> None:
    """Both links, until this Pi takes the VIP. Raises aiomqtt.MqttError when a link drops."""
    import aiomqtt

    def client(host: str, side: str) -> aiomqtt.Client:
        return aiomqtt.Client(hostname=host, port=MQTT_PORT, username="hub", password=password,
                              identifier=f"canary-relay-{node}-{side}", keepalive=KEEPALIVE_S,
                              protocol=aiomqtt.ProtocolVersion.V5, clean_start=True)

    async with client(local_host, "local") as local, client(vip, "up") as upstream:
        await local.subscribe("#", qos=1)
        await upstream.subscribe("#", qos=1)
        log.info("relaying between %s and %s", local_host, vip)
        tasks = [
            asyncio.create_task(_pump(local, upstream, goes_up, keep_retained, "up")),
            asyncio.create_task(_pump(upstream, local, goes_down, lambda _: False, "down")),
            asyncio.create_task(_until_holding(vip)),
        ]
        try:
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()  # a pump that ended raises the link's error here
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


async def run(vip: str, local_host: str, node: str, password: str) -> None:
    import aiomqtt

    idle = False
    while True:
        if holds_address(vip):
            if not idle:
                log.info("this Pi holds %s: idle", vip)
                idle = True
            await asyncio.sleep(HOLDER_CHECK_S)
            continue
        idle = False
        try:
            await _relay_until_holding(vip, local_host, node, password)
        except aiomqtt.MqttError as exc:
            log.warning("link down (%s); retrying in %.0f s", exc, RETRY_S)
            await asyncio.sleep(RETRY_S)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="[relay] %(message)s", stream=sys.stdout)
    logging.getLogger("aiomqtt").setLevel(logging.WARNING)
    vip = os.environ.get("CANARY_VIP", "")
    password = os.environ.get("CANARY_MQTT_PASSWORD", "")
    if not vip or not password:
        sys.exit("relay: CANARY_VIP and CANARY_MQTT_PASSWORD are required")
    asyncio.run(run(vip, os.environ.get("CANARY_RELAY_LOCAL_HOST", "127.0.0.1"),
                    os.environ.get("CANARY_NODE_NAME", "hub"), password))


if __name__ == "__main__":
    main()
