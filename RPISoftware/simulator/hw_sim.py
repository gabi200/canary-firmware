#!/usr/bin/env python3
"""Firmware-accurate Canary hardware simulator: one air node + one water node.

Behaves on MQTT like the real firmware (../../air_sensor, ../../water_sensor;
the contract is docs/HARDWARE.md):

* one MQTT 3.1.1 connection per node, client id "<device name>-<6 hex chip id>",
  keepalive 30 s, last will "offline" (QoS 1, retained) on <base>/availability;
* after connecting: retained "online", then a retained status snapshot;
* retained <base>/status on every state change plus a heartbeat (air 15 s,
  water 60 s). Like the firmware, a changed reading that does not change any
  state (e.g. CO 3 -> 20 ppm, radar presence) only shows up in the next heartbeat;
* the firmware's status documents (same fields, same key order), with the
  dependent fields derived by the firmware's rules: channel state from the
  device thresholds with the 3 s trigger / 30 s clear holds, alarm state and
  hazard (CO > gas > particulate), LED colour/blink, water debounce, leak
  latch, valve and the 180 s alarm timeout;
* commands like the firmware: <base>/buzzer/set (air SILENCE|TEST, water
  SILENCE) and <base>/valve/set (water OPEN|CLOSE), answered on
  <base>/command/result.

--fast runs every firmware timer, heartbeat and scenario step 5x faster
(uptime_ms included, so it stays consistent).

Examples:
    python hw_sim.py --scenario normal                  # steady state until Ctrl-C
    python hw_sim.py --scenario co --fast               # CO warning -> danger -> clear
    MQTT_USERNAME=hub MQTT_PASSWORD=... python hw_sim.py --scenario leak
    docker compose --profile sim run --rm hw-sim --scenario all --fast --exit
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import queue
import random
import signal
import socket
import string
import sys
import threading
import time
from typing import Callable, Iterator

import paho.mqtt.client as mqtt

FIRMWARE_VERSION = "1.0.0"      # HardwareConfig.h FIRMWARE_VERSION (both devices)
KEEPALIVE_S = 30                # MqttService.cpp MQTT_KEEPALIVE_SECONDS
COMMAND_BYTES = 24              # MqttService.cpp COMMAND_BYTES: longer payloads are invalid
BOOT_TO_MQTT_S = 4.0            # boot -> Wi-Fi joined -> broker connected, roughly
TICK_S = 0.1                    # real seconds between simulation steps
CLIENT_ID_CHARS = set(string.ascii_letters + string.digits + "-_")
_T0 = time.monotonic()

Scenario = Iterator[None]       # a scenario is a generator; every `yield` is one tick


def log(who: str, text: str) -> None:
    print(f"[{time.monotonic() - _T0:7.1f}s] {who:<14} {text}", flush=True)


def ceil_seconds(ms: float) -> int:
    """Firmware toSeconds(): milliseconds rounded up to whole seconds."""
    return (max(0, int(ms)) + 999) // 1000


def tenths(value: float) -> float | int:
    """Firmware toTenths(): one decimal; ArduinoJson prints 22.0 as 22."""
    t = round(value * 10)
    return t // 10 if t % 10 == 0 else t / 10


class Clock:
    """Virtual seconds since start. Every firmware timer runs on this clock."""

    def __init__(self, scale: float) -> None:
        self.scale = scale
        self._t0 = time.monotonic()

    def now(self) -> float:
        return (time.monotonic() - self._t0) * self.scale

    def real(self) -> float:
        return time.monotonic() - self._t0


class ConnectError(Exception):
    pass


# ============================================================ MQTT node base


class Node:
    """The firmware's MqttService plus the pieces every device shares."""

    heartbeat_s = 0.0
    command_topics: tuple[str, ...] = ()

    def __init__(self, base: str, clock: Clock, args: argparse.Namespace) -> None:
        self.base = base
        self.name = base[:32]  # device.name; the firmware defaults use name == base topic
        self.clock = clock
        self.args = args
        safe = "".join(c if c in CLIENT_ID_CHARS else "-" for c in self.name) or "device"
        self.client_id = f"{safe}-{random.getrandbits(24):06x}"  # "<name>-<chip id>"
        self.client: mqtt.Client | None = None
        self.connected = False
        self.connect_error: str | None = None
        self._just_connected = False
        self._reasons: list[str] = []
        self.commands: queue.Queue[tuple[str, bytes]] = queue.Queue()
        self.hb_anchor = 0.0
        self.boot_at = 0.0
        self.rssi = -60

    # --- device model hooks (subclasses) -------------------------------
    def boot(self, now: float) -> None:
        raise NotImplementedError

    def step(self, now: float) -> bool:
        """One pass of the device's safety loop; True when a state changed."""
        raise NotImplementedError

    def status(self, now: float) -> dict:
        raise NotImplementedError

    def summary(self, now: float) -> str:
        raise NotImplementedError

    def command(self, suffix: str, cmd: str, now: float) -> tuple[str, bool, str]:
        raise NotImplementedError

    # --- helpers --------------------------------------------------------
    def topic(self, suffix: str) -> str:
        return f"{self.base}/{suffix}"

    def uptime_ms(self, now: float) -> int:
        return int((now - self.boot_at) * 1000)

    def fast_forward(self, until: float) -> None:
        """Run the safety loop from boot up to `until` (before MQTT is up)."""
        t = self.boot_at
        while t < until:
            self.step(t)
            t += 0.1

    def mark(self, reason: str) -> None:
        if reason not in self._reasons:
            self._reasons.append(reason)

    # --- connection -----------------------------------------------------
    def connect(self) -> None:
        c = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.client_id,
            protocol=mqtt.MQTTv311,
            clean_session=True,
        )
        if self.args.username:  # like PubSubClient: no user -> anonymous connect
            c.username_pw_set(self.args.username, self.args.password)
        c.will_set(self.topic("availability"), "offline", qos=1, retain=True)
        c.reconnect_delay_set(min_delay=1, max_delay=30)  # firmware: 1 s doubling to 30 s
        c.on_connect = self._on_connect
        c.on_disconnect = self._on_disconnect
        c.on_message = self._on_message
        self.client = c
        self.connect_error = None
        c.connect_async(self.args.host, self.args.port, keepalive=KEEPALIVE_S)
        c.loop_start()

    def drop(self) -> None:
        """Lose the connection without an MQTT DISCONNECT (reset, power cut,
        Wi-Fi gone): the broker then publishes this node's last will."""
        c, self.client = self.client, None
        self.connected = False
        if c is None:
            return
        # Stop paho's network thread without waiting for it (loop_stop() joins,
        # and the thread can sit in select() for up to 1 s, which would skew the
        # uptime). Shutting the socket down sends the FIN at once and wakes that
        # thread, which then closes the socket itself.
        threading.Thread(target=c.loop_stop, daemon=True).start()
        sock = c.socket()
        if sock is not None:
            with contextlib.suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)

    def reboot(self, now: float) -> None:
        self.drop()
        self.boot(now)

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if client is not self.client:
            return
        if reason_code.is_failure:
            self.connect_error = str(reason_code)
            log(self.base, f"broker refused the connection: {reason_code}")
            return
        client.publish(self.topic("availability"), "online", qos=0, retain=True)
        for suffix in self.command_topics:
            client.subscribe(self.topic(suffix), qos=1)
        self.connected = True
        self._just_connected = True
        log(self.base, f"connected as {self.client_id} -> {self.topic('availability')} = online (retained)")

    def _on_disconnect(self, client, userdata, flags, reason_code, properties) -> None:
        if client is self.client and self.connected:
            self.connected = False
            log(self.base, f"connection lost ({reason_code}); reconnecting")

    def _on_message(self, client, userdata, message) -> None:
        if client is self.client:
            self.commands.put((message.topic, bytes(message.payload)))

    # --- the firmware MqttService loop ------------------------------------
    def service(self, now: float) -> None:
        while not self.commands.empty():
            self._handle_command(*self.commands.get_nowait(), now)
        if self.step(now):
            self.mark("change")
        if not self.connected or self.client is None:
            return
        if self._just_connected:  # firmware: drop the pending snapshot, publish a fresh one
            self._just_connected = False
            self._reasons.clear()
            self.hb_anchor = now
            self.mark("connect")
        if now - self.hb_anchor >= self.heartbeat_s:
            self.hb_anchor = now
            self.mark("heartbeat")
        if self._reasons:
            doc = self.status(now)
            payload = json.dumps(doc, separators=(",", ":"))
            self.client.publish(self.topic("status"), payload, qos=0, retain=True)
            log(self.base, f"status [{'+'.join(self._reasons)}] {self.summary(now)}")
            if self.args.verbose:
                print(payload, flush=True)
            self._reasons.clear()

    def _handle_command(self, topic: str, payload: bytes, now: float) -> None:
        suffix = topic[len(self.base) + 1:]
        if len(payload) >= COMMAND_BYTES:
            name, accepted, detail = "UNKNOWN", False, "invalid_command"
        else:
            cmd = payload.decode("ascii", "replace").strip(" \t\r\n\f\v").upper()
            name, accepted, detail = self.command(suffix, cmd, now)
        result = {"command": name, "accepted": accepted, ("state" if accepted else "error"): detail}
        if self.client is not None and self.connected:
            self.client.publish(self.topic("command/result"), json.dumps(result, separators=(",", ":")),
                                qos=0, retain=False)
        log(self.base, f"command {suffix} {payload[:32]!r} -> {result}")
        self.mark("command")


# ============================================================ air node (ESP32-S3)

# Firmware defaults (air_sensor/DeviceConfig.cpp); the status document carries
# them and the hub uses them as the reading thresholds.
CO_WARN, CO_DANGER = 50, 100
GAS_WARN, GAS_DANGER = 1500, 2200
PM25_WARN, PM25_DANGER = 35, 150
PM10_WARN, PM10_DANGER = 100, 250

RANK = {"warmup": 0, "ok": 0, "fault": 1, "warning": 2, "danger": 3}  # severityRank()
HAZARD_LED = {"co": "red", "gas": "orange", "particulate": "magenta"}   # hazardColor()

PRESENCE_STILL = {"detected": True, "moving": False, "stationary": True,
                  "moving_distance_cm": 0, "moving_energy": 0,
                  "stationary_distance_cm": 142, "stationary_energy": 61,
                  "detection_distance_cm": 142}
PRESENCE_MOVING = {"detected": True, "moving": True, "stationary": False,
                   "moving_distance_cm": 231, "moving_energy": 57,
                   "stationary_distance_cm": 0, "stationary_energy": 0,
                   "detection_distance_cm": 231}
PRESENCE_EMPTY = {"detected": False, "moving": False, "stationary": False,
                  "moving_distance_cm": 0, "moving_energy": 0,
                  "stationary_distance_cm": 0, "stationary_energy": 0,
                  "detection_distance_cm": 0}


def level_for(value: int, warn: int, danger: int) -> str:
    return "danger" if value >= danger else "warning" if value >= warn else "ok"


class Channel:
    """AirController::Channel + applyObservation()."""

    def __init__(self) -> None:
        self.state = "warmup"
        self.candidate: str | None = None
        self.since = 0.0

    def apply(self, observed: str, now: float) -> bool:
        if observed == self.state:
            self.candidate = None
            return False
        # Warm-up and fault are debounced by their own clocks: switch at once.
        if observed in ("warmup", "fault") or self.state in ("warmup", "fault"):
            self.state, self.candidate = observed, None
            return True
        if self.candidate != observed:
            self.candidate, self.since = observed, now
            return False
        hold = AirNode.TRIGGER_HOLD_S if RANK[observed] > RANK[self.state] else AirNode.CLEAR_HOLD_S
        if now - self.since < hold:
            return False
        self.state, self.candidate = observed, None
        return True


class AirNode(Node):
    heartbeat_s = 15.0          # air_sensor/MqttService.cpp STATUS_HEARTBEAT_MS
    command_topics = ("buzzer/set",)
    TRIGGER_HOLD_S = 3.0        # HardwareConfig.h ALARM_TRIGGER_HOLD_MS
    CLEAR_HOLD_S = 30.0         # ALARM_CLEAR_HOLD_MS
    SILENCE_S = 300.0           # portal default "Alarm silence seconds"
    SELF_TEST_S = 4.0           # SELF_TEST_MS

    def __init__(self, base: str, clock: Clock, args: argparse.Namespace) -> None:
        super().__init__(base, clock, args)
        self.warmup_s = args.warmup
        self.rssi = -61
        # Environment driven by the scenarios (integers like the sensor frames).
        self.co_ppm = 3
        self.gas_adc = 640
        self.pm1_0, self.pm2_5, self.pm10 = 4, 7, 9
        self.temp_c, self.humidity = 22.4, 41.5
        self.presence = dict(PRESENCE_STILL)

    # -- scenario setters
    def set_co(self, v: float) -> None:
        self.co_ppm = int(round(v))

    def set_gas(self, v: float) -> None:
        self.gas_adc = int(round(v))

    def set_smoke(self, level: float) -> None:
        """0 = clean air, 1 = heavy smoke (PM2.5 190, PM10 265 ug/m3: both danger)."""
        self.pm1_0 = int(round(4 + 116 * level))
        self.pm2_5 = int(round(7 + 183 * level))
        self.pm10 = int(round(9 + 256 * level))

    # -- AirController
    def boot(self, now: float) -> None:  # RAM state, reset on every boot
        self.boot_at = now
        self.channels = {name: Channel() for name in ("co", "gas", "particulate")}
        self.peaks = {"co": 0, "gas": 0, "pm2_5": 0, "pm10": 0}
        self.alarm_state, self.alarm_hazard = "inactive", "none"
        self.pattern_epoch = now
        self.silence_active, self.silenced_hazard, self.silenced_until = False, "none", 0.0
        self.self_test_running, self.self_test_started = False, 0.0

    def warming_up(self, now: float) -> bool:
        return now - self.boot_at < self.warmup_s

    def observe(self, name: str, now: float) -> str:
        if self.warming_up(now):
            return "warmup"
        if name == "co":
            return level_for(self.co_ppm, CO_WARN, CO_DANGER)
        if name == "gas":
            return level_for(self.gas_adc, GAS_WARN, GAS_DANGER)
        fine = level_for(self.pm2_5, PM25_WARN, PM25_DANGER)
        coarse = level_for(self.pm10, PM10_WARN, PM10_DANGER)
        return coarse if RANK[coarse] > RANK[fine] else fine

    def worst_at(self, level: str) -> str:
        for hazard in ("co", "gas", "particulate"):  # priority order
            if self.channels[hazard].state == level:
                return hazard
        return "none"

    def any_channel(self, level: str) -> bool:
        return any(ch.state == level for ch in self.channels.values())

    def self_test_active(self, now: float) -> bool:
        return self.self_test_running and now - self.self_test_started < self.SELF_TEST_S

    def step(self, now: float) -> bool:
        if not self.warming_up(now):  # peaks only count after warm-up
            self.peaks["co"] = max(self.peaks["co"], self.co_ppm)
            self.peaks["gas"] = max(self.peaks["gas"], self.gas_adc)
            self.peaks["pm2_5"] = max(self.peaks["pm2_5"], self.pm2_5)
            self.peaks["pm10"] = max(self.peaks["pm10"], self.pm10)
        changed = False
        for name, channel in self.channels.items():
            changed = channel.apply(self.observe(name, now), now) or changed
        danger, warning = self.worst_at("danger"), self.worst_at("warning")
        if danger != "none" and self.self_test_running:  # a real hazard outranks a test
            self.self_test_running, changed = False, True
        if self.self_test_running and now - self.self_test_started >= self.SELF_TEST_S:
            self.self_test_running, changed = False, True
        if self.silence_active and (danger == "none" or danger != self.silenced_hazard
                                    or now >= self.silenced_until):
            self.silence_active, changed = False, True
        if danger != "none":
            state, hazard = ("silenced" if self.silence_active else "sounding"), danger
        elif warning != "none":
            state, hazard = "warning", warning
        else:
            state, hazard = "inactive", "none"
        if (state, hazard) != (self.alarm_state, self.alarm_hazard):
            self.alarm_state, self.alarm_hazard, self.pattern_epoch = state, hazard, now
            changed = True
        return changed

    def led_color(self, now: float) -> str:
        if self.self_test_active(now):
            step = min(3, int((now - self.self_test_started) / (self.SELF_TEST_S / 4)))
            return ("red", "orange", "magenta", "white")[step]
        if self.alarm_hazard != "none":
            return HAZARD_LED[self.alarm_hazard]
        if self.any_channel("fault"):
            return "cyan"
        if self.any_channel("warmup"):
            return "blue"
        return "green"

    def led_on(self, now: float) -> bool:
        if self.self_test_active(now):
            return True
        if self.alarm_state in ("sounding", "silenced"):
            on, off = 200, 200
        elif self.alarm_state == "warning":
            on, off = 400, 1600
        elif self.any_channel("fault"):
            on, off = 120, 880
        elif self.any_channel("warmup"):
            on, off = 1000, 1000
        else:
            return True
        return int((now - self.pattern_epoch) * 1000) % (on + off) < on

    def command(self, suffix: str, cmd: str, now: float) -> tuple[str, bool, str]:
        if suffix == "buzzer/set" and cmd == "SILENCE":
            if self.alarm_state != "sounding":
                return "SILENCE", False, "alarm_inactive"
            self.silence_active, self.silenced_hazard = True, self.alarm_hazard
            self.silenced_until = now + self.SILENCE_S
            self.alarm_state, self.pattern_epoch = "silenced", now
            return "SILENCE", True, "silenced"
        if suffix == "buzzer/set" and cmd == "TEST":
            if self.alarm_state in ("sounding", "silenced") or self.self_test_running:
                return "TEST", False, "self_test_busy"
            self.self_test_running, self.self_test_started = True, now
            return "TEST", True, "self_test"
        return "UNKNOWN", False, "invalid_command"

    def status(self, now: float) -> dict:  # air_sensor/StatusJson.cpp, same key order
        age = lambda limit: random.randint(0, limit)  # noqa: E731 - ms since the last frame
        silence_ms = (self.silenced_until - now) * 1000 if self.silence_active else 0
        return {
            "device": {"name": self.name, "firmware": FIRMWARE_VERSION},
            "uptime_ms": self.uptime_ms(now),
            "warmup_remaining_seconds": ceil_seconds(self.warmup_s * 1000 - self.uptime_ms(now)),
            "co": {"ppm": self.co_ppm, "peak_ppm": self.peaks["co"],
                   "state": self.channels["co"].state, "warn_ppm": CO_WARN,
                   "danger_ppm": CO_DANGER, "valid": True, "age_ms": age(999)},
            "gas": {"adc": self.gas_adc, "peak_adc": self.peaks["gas"],
                    "state": self.channels["gas"].state, "warn_adc": GAS_WARN,
                    "danger_adc": GAS_DANGER},
            "particulate": {"pm1_0": self.pm1_0, "pm2_5": self.pm2_5, "pm10": self.pm10,
                            "peak_pm2_5": self.peaks["pm2_5"], "peak_pm10": self.peaks["pm10"],
                            "state": self.channels["particulate"].state,
                            "warn_pm2_5": PM25_WARN, "danger_pm2_5": PM25_DANGER,
                            "warn_pm10": PM10_WARN, "danger_pm10": PM10_DANGER,
                            "valid": True, "age_ms": age(999)},
            "climate": {"temperature_c": tenths(self.temp_c + random.uniform(-0.1, 0.1)),
                        "humidity_percent": tenths(self.humidity + random.uniform(-0.3, 0.3)),
                        "valid": True, "age_ms": age(999)},
            "presence": {**self.presence, "valid": True, "age_ms": age(120)},
            "alarm": {"state": self.alarm_state, "hazard": self.alarm_hazard,
                      "sounding": self.alarm_state == "sounding",
                      "silence_remaining_seconds": ceil_seconds(silence_ms),
                      "self_test": self.self_test_active(now),
                      "led_color": self.led_color(now), "led_on": self.led_on(now)},
            "wifi": {"connected": True, "rssi": self.rssi + random.randint(-2, 2)},
            "mqtt": {"enabled": True, "connected": True},
            "ota": {"in_progress": False},
        }

    def summary(self, now: float) -> str:
        ch = self.channels
        text = (f"co {self.co_ppm}ppm {ch['co'].state} | gas {self.gas_adc} {ch['gas'].state}"
                f" | pm2.5 {self.pm2_5} pm10 {self.pm10} {ch['particulate'].state}"
                f" | presence {'yes' if self.presence['detected'] else 'no'}"
                f" | alarm {self.alarm_state}/{self.alarm_hazard} led {self.led_color(now)}")
        if self.warming_up(now):
            text += f" | warm-up {ceil_seconds(self.warmup_s * 1000 - self.uptime_ms(now))}s left"
        return text


# ============================================================ water node (ESP32-C3)

WET_THRESHOLD, DRY_THRESHOLD = 1200, 600  # water_sensor/DeviceConfig.cpp defaults


class WaterNode(Node):
    heartbeat_s = 60.0          # water_sensor/MqttService.cpp STATUS_HEARTBEAT_MS
    command_topics = ("valve/set", "buzzer/set")
    DEBOUNCE_S = 1.0            # portal default debounce 1000 ms
    ALARM_S = 180.0             # portal default alarm duration 180 s

    def __init__(self, base: str, clock: Clock, args: argparse.Namespace) -> None:
        super().__init__(base, clock, args)
        self.rssi = -58
        self.adc = 312              # driven by the scenarios
        # NVS-persisted, survives reboots: an installed device with the valve opened.
        self.leak_latched = False
        self.requested_valve = "open"

    def set_adc(self, v: float) -> None:
        self.adc = int(round(v))

    # -- LeakController
    def boot(self, now: float) -> None:  # LeakController::restore()
        self.boot_at = now
        self.sensor_state, self.candidate, self.candidate_since = "uninitialized", None, now
        self.valve = "closed"       # applied valve: closed until the probe reads dry
        self.alarm_active, self.alarm_started = False, now
        self.alarm_silenced = self.alarm_timed_out = False
        if self.leak_latched:       # a latched leak sounds again after every boot
            self.start_alarm(now)

    def start_alarm(self, now: float) -> None:
        self.alarm_active, self.alarm_started = True, now
        self.alarm_silenced = self.alarm_timed_out = False

    def step(self, now: float) -> bool:
        changed = self.update_sensor(now)
        if self.alarm_active and not self.alarm_timed_out and now - self.alarm_started >= self.ALARM_S:
            self.alarm_timed_out = changed = True
        return changed

    def update_sensor(self, now: float) -> bool:  # LeakController::updateSensor()
        if self.adc >= WET_THRESHOLD:
            observed = "wet"
        elif self.adc <= DRY_THRESHOLD:
            observed = "dry"
        else:  # between thresholds: hysteresis keeps the candidate / current state
            observed = self.candidate if self.candidate is not None else self.sensor_state
        if observed == "uninitialized":
            return False
        if self.candidate != observed:
            self.candidate, self.candidate_since = observed, now
            return False
        if self.sensor_state == self.candidate or now - self.candidate_since < self.DEBOUNCE_S:
            return False
        self.sensor_state = self.candidate
        if self.sensor_state == "wet":  # enterWet(): latch, close, sound
            self.leak_latched, self.requested_valve, self.valve = True, "closed", "closed"
            self.start_alarm(now)
        elif not self.leak_latched and self.requested_valve == "open":
            self.valve = "open"
        return True

    def alarm_state(self, now: float) -> str:
        if not self.alarm_active:
            return "inactive"
        if self.alarm_timed_out or now - self.alarm_started >= self.ALARM_S:
            return "timed_out"
        return "silenced" if self.alarm_silenced else "sounding"

    def command(self, suffix: str, cmd: str, now: float) -> tuple[str, bool, str]:
        if suffix == "valve/set" and cmd == "CLOSE":
            self.requested_valve = self.valve = "closed"
            return "CLOSE", True, "closed"
        if suffix == "valve/set" and cmd == "OPEN":
            if self.sensor_state == "uninitialized":
                return "OPEN", False, "sensor_uninitialized"
            if self.sensor_state == "wet":
                return "OPEN", False, "sensor_wet"
            self.leak_latched, self.requested_valve, self.valve = False, "open", "open"
            return "OPEN", True, "open"
        if suffix == "buzzer/set" and cmd == "SILENCE":
            if not self.alarm_active or self.alarm_timed_out:
                return "SILENCE", False, "alarm_inactive"
            self.alarm_silenced = True
            return "SILENCE", True, "silenced"
        return "UNKNOWN", False, "invalid_command"

    def status(self, now: float) -> dict:  # water_sensor/StatusJson.cpp, same key order
        state = self.alarm_state(now)
        remaining_ms = (self.ALARM_S - (now - self.alarm_started)) * 1000 if state in ("sounding", "silenced") else 0
        return {
            "device": {"name": self.name, "firmware": FIRMWARE_VERSION},
            "uptime_ms": self.uptime_ms(now),
            "sensor": {"adc": self.adc, "initialized": self.sensor_state != "uninitialized",
                       "state": self.sensor_state, "wet_threshold": WET_THRESHOLD,
                       "dry_threshold": DRY_THRESHOLD},
            "leak_latched": self.leak_latched,
            "valve": {"requested": self.requested_valve, "applied": self.valve,
                      "relay_active": self.valve == "closed"},
            "alarm": {"state": state, "sounding": state == "sounding",
                      "remaining_seconds": ceil_seconds(remaining_ms)},
            "wifi": {"connected": True, "rssi": self.rssi + random.randint(-2, 2)},
            "mqtt": {"enabled": True, "connected": True},
            "ota": {"in_progress": False},
        }

    def summary(self, now: float) -> str:
        return (f"sensor {self.sensor_state} adc {self.adc} | latched {'yes' if self.leak_latched else 'no'}"
                f" | valve {self.requested_valve}/{self.valve} | alarm {self.alarm_state(now)}")


# ============================================================ scenarios


class Sim:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.clock = Clock(5.0 if args.fast else 1.0)
        self.air = AirNode(args.air_base, self.clock, args)
        self.water = WaterNode(args.water_base, self.clock, args)
        self.nodes: list[Node] = [self.air, self.water]

    # -- lifecycle
    def start(self) -> None:
        now = self.clock.now()
        for node in self.nodes:
            node.boot(now - BOOT_TO_MQTT_S)  # powered up a few seconds ago...
            node.fast_forward(now)           # ...so the water probe has already settled
            node.connect()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            errors = [f"{n.base}: {n.connect_error}" for n in self.nodes if n.connect_error]
            if errors:
                raise ConnectError(
                    f"broker {self.args.host}:{self.args.port} refused the login ({'; '.join(errors)}). "
                    f"Check --username/--password (or MQTT_USERNAME/MQTT_PASSWORD); "
                    f"scripts/pi_setup.sh creates the 'hub' user and puts its password in .env.")
            if all(n.connected for n in self.nodes):
                return
            time.sleep(0.05)
        raise ConnectError(f"no answer from the MQTT broker at {self.args.host}:{self.args.port} "
                           f"within 10 s. Is it running and reachable? (--host/--port or MQTT_HOST/MQTT_PORT)")

    def stop(self, quiet: bool = False) -> None:
        for node in self.nodes:
            node.drop()
        if not quiet:
            log("sim", "stopped: connections dropped, the broker publishes each node's will (offline)")

    # -- scenario building blocks (generators: each `yield` = one tick)
    def say(self, text: str) -> None:
        log("scenario", text)

    def wait(self, seconds: float) -> Scenario:
        end = self.clock.now() + seconds
        while self.clock.now() < end:
            yield

    def wait_until(self, condition: Callable[[], bool]) -> Scenario:
        while not condition():
            yield

    def ramp(self, setter: Callable[[float], None], start: float, stop: float, seconds: float) -> Scenario:
        t0 = self.clock.now()
        while True:
            progress = min(1.0, (self.clock.now() - t0) / seconds)
            setter(start + (stop - start) * progress)
            if progress >= 1.0:
                return
            yield

    def send_command(self, node: Node, suffix: str, command: str) -> None:
        """Publish a command the way the hub would (non-retained, QoS 1)."""
        if node.client is not None:
            node.client.publish(node.topic(suffix), command, qos=1, retain=False)
            self.say(f"publish {node.topic(suffix)} {command}")


def prelude(sim: Sim) -> Scenario:
    air = sim.air
    if air.warming_up(sim.clock.now()):
        sim.say(f"air node warming up ({air.warmup_s:g} s after boot): channels 'warmup', LED blue")
        yield from sim.wait_until(lambda: not air.warming_up(sim.clock.now()))
        sim.say("air warm-up done: all channels ok, LED green")
    yield from sim.wait(AirNode.heartbeat_s)  # let the hub see one normal heartbeat


def run_normal(sim: Sim) -> Scenario:
    sim.say("normal: both nodes in steady state; small drifts show up in the heartbeats")
    air, water = sim.air, sim.water
    while True:
        air.set_co(random.randint(1, 5))
        air.set_gas(random.randint(610, 690))
        air.set_smoke(random.uniform(0.0, 0.02))
        air.temp_c = min(24.0, max(21.0, air.temp_c + random.uniform(-0.2, 0.2)))
        air.humidity = min(50.0, max(35.0, air.humidity + random.uniform(-0.5, 0.5)))
        water.set_adc(random.randint(290, 340))
        yield from sim.wait(10)


def hazard_ramp(sim: Sim, setter: Callable[[float], None], low: float, high: float,
                what: str, clear: str) -> Scenario:
    sim.say(what)
    yield from sim.ramp(setter, low, high, 60)
    yield from sim.wait(30)
    sim.say(clear)
    yield from sim.ramp(setter, high, low, 30)
    yield from sim.wait(AirNode.CLEAR_HOLD_S + AirNode.heartbeat_s)


def run_co(sim: Sim) -> Scenario:
    yield from hazard_ramp(
        sim, sim.air.set_co, 3, 160,
        "co: CO 3 -> 160 ppm over 60 s: warning at 50 ppm, danger at 100 ppm "
        "(3 s hold) -> alarm sounding, hazard co, LED red",
        "co: CO falls back to 3 ppm; the channel clears after 30 s below every threshold")


def run_gas(sim: Sim) -> Scenario:
    yield from hazard_ramp(
        sim, sim.air.set_gas, 640, 2600,
        "gas: MQ5 ADC 640 -> 2600 over 60 s (raw counts, not ppm): warning at 1500, "
        "danger at 2200 -> alarm sounding, hazard gas, LED orange",
        "gas: MQ5 ADC falls back to 640; clears after the 30 s hold")


def run_smoke(sim: Sim) -> Scenario:
    yield from hazard_ramp(
        sim, sim.air.set_smoke, 0.0, 1.0,
        "smoke: PM2.5 7 -> 190, PM10 9 -> 265 ug/m3 over 60 s: warning at PM2.5 35, "
        "danger at PM2.5 150 -> alarm sounding, hazard particulate, LED magenta",
        "smoke: air clears; the particulate channel clears after the 30 s hold")


def run_leak(sim: Sim, clear_latch: bool = False) -> Scenario:
    water = sim.water
    sim.say("leak: water reaches the probe -> wet (1 s debounce) -> leak_latched, valve closed, "
            f"alarm sounding for {WaterNode.ALARM_S:g} s")
    yield from sim.ramp(water.set_adc, 312, 1850, 2)
    yield from sim.wait(20)
    sim.say("leak: the probe dries -> sensor dry, but the leak stays latched and the valve closed")
    yield from sim.ramp(water.set_adc, 1850, 240, 5)
    yield from sim.wait_until(lambda: water.alarm_state(sim.clock.now()) == "timed_out")
    sim.say("leak: alarm timed out; still latched: dry, valve closed until someone sends OPEN")
    yield from sim.wait(5)
    if clear_latch:
        sim.send_command(water, "valve/set", "OPEN")
        yield from sim.wait(5)
    else:
        sim.say(f"leak: clear it like a technician: mosquitto_pub ... -t '{water.topic('valve/set')}' -m OPEN")


def run_presence(sim: Sim) -> Scenario:
    air = sim.air
    steps = (("room empty", PRESENCE_EMPTY), ("someone walks in (moving target)", PRESENCE_MOVING),
             ("they sit down (stationary target)", PRESENCE_STILL), ("room empty again", PRESENCE_EMPTY),
             ("back to a stationary person", PRESENCE_STILL))
    for text, presence in steps:
        sim.say(f"presence: {text}; the hub sees it with the next heartbeat (no on-change publish)")
        air.presence = dict(presence)
        yield from sim.wait(2 * AirNode.heartbeat_s)


def run_offline(sim: Sim) -> Scenario:
    air = sim.air
    sim.say("offline: the air node's connection drops without DISCONNECT (router/Wi-Fi reset) -> "
            f"the broker publishes its will: {air.topic('availability')} = offline (retained)")
    air.drop()
    yield from sim.wait(60)
    sim.say("offline: Wi-Fi is back: same boot, so uptime_ms continues; 'online' + status snapshot")
    air.connect()
    yield from sim.wait(AirNode.heartbeat_s)


def run_reboot(sim: Sim) -> Scenario:
    sim.say("reboot: both nodes restart: will 'offline' now, back in ~4 s with uptime_ms reset. "
            "Air warm-up restarts; water restores its leak latch and valve request from flash")
    for node in sim.nodes:
        node.reboot(sim.clock.now())
    yield from sim.wait(BOOT_TO_MQTT_S)
    for node in sim.nodes:
        node.connect()
    yield from prelude(sim)


def run_all(sim: Sim) -> Scenario:
    for body in (run_co, run_gas, run_smoke):
        yield from body(sim)
        yield from sim.wait(10)
    yield from run_leak(sim, clear_latch=True)
    yield from sim.wait(10)
    for body in (run_presence, run_offline, run_reboot):
        yield from body(sim)
        yield from sim.wait(10)


SCENARIOS: dict[str, Callable[[Sim], Scenario]] = {
    "normal": run_normal, "co": run_co, "gas": run_gas, "smoke": run_smoke, "leak": run_leak,
    "presence": run_presence, "offline": run_offline, "reboot": run_reboot, "all": run_all,
}


def script(sim: Sim, name: str) -> Scenario:
    yield from prelude(sim)
    yield from SCENARIOS[name](sim)


# ============================================================ main


def valid_base(value: str) -> str:
    if not value or len(value) > 64 or any(c in value for c in "+#") or value.startswith("/"):
        raise argparse.ArgumentTypeError("1-64 characters, no MQTT wildcards (+ #), no leading '/'")
    return value


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Firmware-accurate Canary air + water sensor simulator (MQTT).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="scenarios:\n"
               "  normal    steady state with small drifts (default; runs until stopped)\n"
               "  co        CO ramps through warning into danger and back\n"
               "  gas       MQ5 ADC ramps through warning into danger and back\n"
               "  smoke     PM2.5/PM10 ramp through warning into danger and back\n"
               "  leak      water wet -> alarm sounding, valve closed, latched; then dry but latched\n"
               "  presence  radar presence toggles (empty / moving / stationary)\n"
               "  offline   the air node drops off the broker (will 'offline') and comes back\n"
               "  reboot    both nodes restart (uptime_ms resets)\n"
               "  all       co, gas, smoke, leak (+ OPEN), presence, offline, reboot\n\n"
               "After a scenario the nodes stay online in their final state until Ctrl-C\n"
               "(or --exit / --duration). Stopping drops both connections, so the broker\n"
               "publishes their last will 'offline', exactly as when a device is unplugged.")
    p.add_argument("--scenario", default="normal", choices=sorted(SCENARIOS))
    p.add_argument("--host", default=os.environ.get("MQTT_HOST", "localhost"),
                   help="broker host (env MQTT_HOST, default localhost)")
    p.add_argument("--port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")),
                   help="broker port (env MQTT_PORT, default 1883)")
    p.add_argument("--username", default=os.environ.get("MQTT_USERNAME") or None,
                   help="broker user (env MQTT_USERNAME)")
    p.add_argument("--password", default=os.environ.get("MQTT_PASSWORD") or None,
                   help="broker password (prefer env MQTT_PASSWORD: arguments are visible to other local users)")
    p.add_argument("--air-base", type=valid_base, default="canary",
                   help="air node MQTT base topic (default canary, the firmware default)")
    p.add_argument("--water-base", type=valid_base, default="water-sensor",
                   help="water node MQTT base topic (default water-sensor, the firmware default)")
    p.add_argument("--fast", action="store_true",
                   help="run firmware timers, heartbeats (air 3 s, water 12 s) and scenarios 5x faster")
    p.add_argument("--warmup", type=float, default=20.0,
                   help="air sensor warm-up after boot, seconds (firmware default 300; 0 = none; default 20)")
    p.add_argument("--duration", type=float, default=0.0,
                   help="stop after this many real seconds (default 0 = until Ctrl-C)")
    p.add_argument("--exit", action="store_true", help="stop as soon as the scenario has finished")
    p.add_argument("-v", "--verbose", action="store_true", help="also print every status document")
    args = p.parse_args(argv)
    if args.air_base == args.water_base:
        p.error("--air-base and --water-base must differ: every device needs a unique base topic")
    if args.warmup < 0:
        p.error("--warmup must be >= 0")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    def on_sigterm(signum, frame):  # docker stop -> clean shutdown path
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_sigterm)
    sim = Sim(args)
    log("sim", f"broker {args.host}:{args.port} as {args.username or '(anonymous)'}; air '{args.air_base}' "
               f"(heartbeat {AirNode.heartbeat_s / sim.clock.scale:g} s), water '{args.water_base}' "
               f"(heartbeat {WaterNode.heartbeat_s / sim.clock.scale:g} s); scenario {args.scenario}"
               f"{' (fast x5)' if args.fast else ''}")
    try:
        sim.start()
        steps: Scenario | None = script(sim, args.scenario)
        while True:
            if steps is not None:
                try:
                    next(steps)
                except StopIteration:
                    steps = None
                    if args.exit:
                        log("scenario", f"{args.scenario} finished")
                        break
                    log("scenario", f"{args.scenario} finished; nodes stay online (Ctrl-C to stop)")
            now = sim.clock.now()
            for node in sim.nodes:
                node.service(now)
            if args.duration and sim.clock.real() >= args.duration:
                break
            time.sleep(TICK_S)
    except ConnectError as exc:
        log("sim", f"error: {exc}")
        sim.stop(quiet=True)
        return 1
    except KeyboardInterrupt:
        pass
    sim.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
