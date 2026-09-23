"""Per-sensor-type detection / critical / clear thresholds.

MVP values are illustrative engineering defaults, not certified life-safety
setpoints. combustible_gas is expressed in ppm here; a production system would
normally work in %LEL with sensor-specific calibration. These live in code for
the MVP; they belong in per-device/per-zone config in a later phase.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.enums import SensorType


@dataclass(frozen=True)
class Thresholds:
    detection: float  # value at/above which we open a detection
    critical: float  # value at/above which the single-sensor critical fast-path fires
    clear: float  # value below which the reading counts toward clearing
    units: str


THRESHOLDS: dict[SensorType, Thresholds] = {
    SensorType.combustible_gas: Thresholds(detection=1000.0, critical=5000.0, clear=500.0, units="ppm"),
    SensorType.co: Thresholds(detection=50.0, critical=150.0, clear=35.0, units="ppm"),
    # water_leak is effectively boolean: any wet reading (>=1) is a leak.
    SensorType.water_leak: Thresholds(detection=1.0, critical=1.0, clear=0.5, units="bool"),
}


def thresholds_for(sensor_type: SensorType) -> Thresholds | None:
    return THRESHOLDS.get(sensor_type)
