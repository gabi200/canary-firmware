"""Per-sensor-type detection / critical / clear thresholds.

MVP values are illustrative engineering defaults, not certified life-safety
setpoints. combustible_gas is expressed in ppm here; a production system would
normally work in %LEL with sensor-specific calibration. These are the fallback:
a reading that carries its device's own thresholds (the installer calibration,
e.g. the air node's raw MQ5 ADC counts, which are not ppm) is graded with those.
"""

from __future__ import annotations

import math
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
    # PM2.5; alarms but never auto-evacuates (not in AUTO_EVAC_HAZARDS).
    SensorType.particulate: Thresholds(detection=35.0, critical=150.0, clear=25.0, units="ug/m3"),
}


def thresholds_for(sensor_type: SensorType) -> Thresholds | None:
    return THRESHOLDS.get(sensor_type)


def effective_thresholds(sensor_type: SensorType, device: Thresholds | None = None) -> Thresholds | None:
    """Thresholds to grade a reading with: the device's own when it sent them, else the
    backend default. None for sensor types that are never a hazard (presence)."""
    default = thresholds_for(sensor_type)
    if default is None:
        return None
    if device is None or not _sane(device):
        return default
    return device


def _sane(th: Thresholds) -> bool:
    """The firmware's own invariant (0 < warn < danger), mapped to clear <= detection.
    Without it a broken or spoofed document could make a normal reading critical
    (0/0 thresholds -> evacuation) and the incident impossible to clear."""
    values = (th.clear, th.detection, th.critical)
    return all(math.isfinite(v) for v in values) and 0 < th.clear <= th.detection < th.critical
