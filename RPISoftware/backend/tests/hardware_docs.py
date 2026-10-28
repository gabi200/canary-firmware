"""Firmware status documents for tests: the docs/HARDWARE.md samples, verbatim, plus
builders that patch individual sections."""

from __future__ import annotations

import copy

# docs/HARDWARE.md section 1: water status document (ESP32-C3)
WATER_SAMPLE = {
    "device": {"name": "water-sensor", "firmware": "1.0.0"},
    "uptime_ms": 123456,
    "sensor": {"adc": 312, "initialized": True, "state": "dry", "wet_threshold": 1200, "dry_threshold": 600},
    "leak_latched": False,
    "valve": {"requested": "open", "applied": "open", "relay_active": False},
    "alarm": {"state": "inactive", "sounding": False, "remaining_seconds": 0},
    "wifi": {"connected": True, "rssi": -58},
    "mqtt": {"enabled": True, "connected": True},
    "ota": {"in_progress": False},
}

# docs/HARDWARE.md section 1: air status document (ESP32-S3)
AIR_SAMPLE = {
    "device": {"name": "canary", "firmware": "1.0.0"},
    "uptime_ms": 600000,
    "warmup_remaining_seconds": 0,
    "co": {"ppm": 3, "peak_ppm": 7, "state": "ok", "warn_ppm": 50, "danger_ppm": 100, "valid": True, "age_ms": 800},
    "gas": {"adc": 640, "peak_adc": 910, "state": "ok", "warn_adc": 1500, "danger_adc": 2200},
    "particulate": {
        "pm1_0": 4, "pm2_5": 7, "pm10": 9, "peak_pm2_5": 31, "peak_pm10": 44, "state": "ok",
        "warn_pm2_5": 35, "danger_pm2_5": 150, "warn_pm10": 100, "danger_pm10": 250, "valid": True, "age_ms": 900,
    },
    "climate": {"temperature_c": 22.4, "humidity_percent": 41.5, "valid": True, "age_ms": 900},
    "presence": {
        "detected": True, "moving": False, "stationary": True, "moving_distance_cm": 0, "moving_energy": 0,
        "stationary_distance_cm": 142, "stationary_energy": 61, "detection_distance_cm": 142,
        "valid": True, "age_ms": 120,
    },
    "gas_detector": {"alarm": False},
    "alarm": {
        "state": "inactive", "hazard": "none", "sounding": False, "silence_remaining_seconds": 0,
        "self_test": False, "led_color": "green", "led_on": True,
    },
    "wifi": {"connected": True, "rssi": -61},
    "mqtt": {"enabled": True, "connected": True},
    "ota": {"in_progress": False},
}


def _build(sample: dict, uptime_ms: int | None, sections: dict) -> dict:
    doc = copy.deepcopy(sample)
    if uptime_ms is not None:
        doc["uptime_ms"] = uptime_ms
    for key, patch in sections.items():
        if isinstance(patch, dict) and isinstance(doc.get(key), dict):
            doc[key].update(patch)
        else:
            doc[key] = patch
    return doc


def air_doc(uptime_ms: int | None = None, **sections) -> dict:
    """AIR_SAMPLE with `section={field: value}` patches (non-dict values replace)."""
    return _build(AIR_SAMPLE, uptime_ms, sections)


def water_doc(uptime_ms: int | None = None, **sections) -> dict:
    """WATER_SAMPLE with `section={field: value}` patches (non-dict values replace)."""
    return _build(WATER_SAMPLE, uptime_ms, sections)
