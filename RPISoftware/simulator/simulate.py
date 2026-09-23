#!/usr/bin/env python3
"""Canary sensor simulator.

Publishes canary.telemetry.v1 messages over MQTT so the full
detection -> alarm -> evacuation -> victim-accounting path runs with no hardware.

For the real sensors' MQTT format (air/water status documents) use hw_sim.py.

Examples:
    python simulate.py --scenario presence            # seed occupancy for accounting
    python simulate.py --scenario gas_leak            # ramp kitchen gas to critical -> evacuation
    python simulate.py --scenario co                  # ramp bedroom CO
    python simulate.py --scenario water_leak
    python simulate.py --scenario normal --duration 60

The broker requires a login (docker-compose Mosquitto): pass --username/--password
or set MQTT_USERNAME / MQTT_PASSWORD (preferred: arguments are visible to other
local users). MQTT_HOST / MQTT_PORT set the default broker address.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

PREFIX = "canary/v1"
BUILDING = "bld_007"
FLOOR = "flr_03"

# device_id -> (floor, unit, zone, sensor_type, units)
DEVICES = {
    "dev_gas_kitchen": (FLOOR, "unit_0312", "zone_kitchen", "combustible_gas", "ppm"),
    "dev_leak_kitchen": (FLOOR, "unit_0312", "zone_kitchen", "water_leak", "bool"),
    "dev_co_bedroom": (FLOOR, "unit_0312", "zone_bedroom", "co", "ppm"),
    "dev_co_boiler": (FLOOR, "common", "zone_boiler", "co", "ppm"),
    "dev_gas_boiler": (FLOOR, "common", "zone_boiler", "combustible_gas", "ppm"),
    "dev_presence_unit": (FLOOR, "common", "zone_hallway", "wifi_presence", "persons_est"),
    "dev_presence_bedroom": (FLOOR, "unit_0312", "zone_bedroom", "wifi_presence", "persons_est"),
}

_seq: dict[str, int] = {}


def _next_seq(device_id: str) -> int:
    _seq[device_id] = _seq.get(device_id, 0) + 1
    return _seq[device_id]


def edge_state_for(sensor_type: str, value: float) -> str:
    if sensor_type == "combustible_gas":
        return "alarm" if value >= 5000 else "warn" if value >= 1000 else "normal"
    if sensor_type == "co":
        return "alarm" if value >= 150 else "warn" if value >= 50 else "normal"
    if sensor_type == "water_leak":
        return "alarm" if value >= 1 else "normal"
    return "normal"


def make_payload(device_id: str, value: float) -> dict:
    floor, unit, zone, sensor_type, units = DEVICES[device_id]
    now = datetime.now(timezone.utc).isoformat()
    return {
        "schema": "canary.telemetry.v1",
        "device_id": device_id,
        "sensor_type": sensor_type,
        "location": {"building_id": BUILDING, "floor_id": floor, "unit_id": unit, "zone_id": zone},
        "value": value,
        "units": units,
        "edge_state": edge_state_for(sensor_type, value),
        "edge_inference_score": 0.8,
        "signal": {"rssi": -67, "snr": 9.5, "link": "wifi"},
        "health": {"status": "ok", "self_test": "pass"},
        "battery": {"level_pct": 88, "powered": "mains", "low_battery": False},
        "fw_version": "1.4.2",
        "epoch": 1,
        "seq": _next_seq(device_id),
        "device_ts": now,
    }


def topic_for(device_id: str) -> str:
    floor, unit, zone, _, _ = DEVICES[device_id]
    return f"{PREFIX}/{BUILDING}/{floor}/{unit}/{zone}/{device_id}/telemetry"


def publish(client: mqtt.Client, device_id: str, value: float) -> None:
    payload = make_payload(device_id, value)
    client.publish(topic_for(device_id), json.dumps(payload), qos=1)
    print(f"  -> {device_id:20s} {payload['sensor_type']:16s} value={value:<7} edge={payload['edge_state']}")


def seed_presence(client: mqtt.Client) -> None:
    """Publish baseline occupancy so victim-accounting has people to reconcile."""
    print("[presence] seeding occupancy estimates")
    publish(client, "dev_presence_unit", 2)  # 2 in hallway
    publish(client, "dev_presence_bedroom", 1)  # 1 in bedroom


def ramp(client: mqtt.Client, device_id: str, start: float, end: float, steps: int, interval: float) -> None:
    for i in range(steps + 1):
        value = round(start + (end - start) * i / steps, 1)
        publish(client, device_id, value)
        time.sleep(interval)


def run(args: argparse.Namespace) -> None:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="canary-simulator")
    if args.username:
        client.username_pw_set(args.username, args.password)
    connack: list = []
    client.on_connect = lambda c, userdata, flags, reason_code, props: connack.append(reason_code)
    try:
        client.connect(args.host, args.port, keepalive=30)
    except OSError as exc:
        sys.exit(f"[simulator] cannot reach the MQTT broker at {args.host}:{args.port}: {exc}")
    client.loop_start()
    deadline = time.time() + 10
    while not connack and time.time() < deadline:
        time.sleep(0.05)
    if not connack or connack[0].is_failure:
        client.loop_stop()
        why = connack[0] if connack else "no CONNACK within 10 s"
        sys.exit(f"[simulator] broker {args.host}:{args.port} refused the connection ({why}); "
                 "check --username/--password or MQTT_USERNAME/MQTT_PASSWORD")
    print(f"[simulator] connected to {args.host}:{args.port}, scenario={args.scenario}")

    if args.scenario in ("presence", "gas_leak", "co", "water_leak", "all"):
        seed_presence(client)
        time.sleep(args.interval)

    if args.scenario == "presence":
        pass
    elif args.scenario == "gas_leak":
        print("[gas_leak] ramping kitchen combustible_gas 200 -> 6000 ppm (-> critical -> evacuation)")
        ramp(client, "dev_gas_kitchen", 200, 6000, steps=12, interval=args.interval)
    elif args.scenario == "co":
        print("[co] ramping bedroom CO 5 -> 200 ppm")
        ramp(client, "dev_co_bedroom", 5, 200, steps=12, interval=args.interval)
    elif args.scenario == "water_leak":
        print("[water_leak] kitchen leak detected")
        publish(client, "dev_leak_kitchen", 0)
        time.sleep(args.interval)
        publish(client, "dev_leak_kitchen", 1)
    elif args.scenario == "all":
        ramp(client, "dev_gas_kitchen", 200, 6000, steps=12, interval=args.interval)
    elif args.scenario == "normal":
        end = time.time() + args.duration
        while time.time() < end:
            publish(client, "dev_gas_kitchen", 120)
            publish(client, "dev_co_bedroom", 3)
            time.sleep(args.interval)

    time.sleep(1.0)
    client.loop_stop()
    client.disconnect()
    print("[simulator] done")


def main() -> None:
    p = argparse.ArgumentParser(description="Canary sensor simulator")
    p.add_argument("--host", default=os.environ.get("MQTT_HOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    p.add_argument("--username", default=os.environ.get("MQTT_USERNAME") or None)
    p.add_argument("--password", default=os.environ.get("MQTT_PASSWORD") or None,
                   help="prefer env MQTT_PASSWORD: arguments are visible to other local users")
    p.add_argument(
        "--scenario",
        default="gas_leak",
        choices=["normal", "gas_leak", "co", "water_leak", "presence", "all"],
    )
    p.add_argument("--interval", type=float, default=1.0, help="seconds between samples")
    p.add_argument("--duration", type=float, default=30.0, help="seconds (normal scenario)")
    run(p.parse_args())


if __name__ == "__main__":
    main()
