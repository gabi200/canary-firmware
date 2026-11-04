"""Pure hardware translation: firmware status documents -> canonical payloads."""

from __future__ import annotations

from app.enums import EdgeState, NodeKind, SensorType
from app.ingestion.hardware import detect_kind, node_id_for, parse_document, status_to_payloads, uptime_ms
from app.schemas import Location
from tests.hardware_docs import AIR_SAMPLE, WATER_SAMPLE, air_doc, water_doc

LOC = Location(building_id="bld_007", floor_id="flr_03", unit_id="common", zone_id="zone_hallway")


def _payloads(kind: NodeKind, doc: dict, node_id: str = "canary", epoch: int = 1) -> dict:
    out = status_to_payloads(kind, doc, node_id=node_id, location=LOC, epoch=epoch, seq=doc["uptime_ms"])
    return {p.device_id: p for p in out}


def _th(payload) -> tuple:
    t = payload.thresholds
    return (t.detection, t.critical, t.clear)


def test_air_sample_translates_per_contract():
    ps = _payloads(NodeKind.air, AIR_SAMPLE)
    assert list(ps) == ["canary:co", "canary:gas", "canary:particulate", "canary:gas_detector", "canary:presence"]

    co, gas, pm, detector, presence = ps.values()
    assert (co.sensor_type, co.value, co.units, co.edge_state) == (SensorType.co, 3, "ppm", EdgeState.normal)
    assert _th(co) == (50, 100, 50)  # detection = clear = warn_ppm, critical = danger_ppm
    # MQ5 value is a raw ADC count and carries the device's ADC thresholds (never ppm defaults)
    assert (gas.sensor_type, gas.value, gas.units) == (SensorType.combustible_gas, 640, "adc")
    assert _th(gas) == (1500, 2200, 1500)
    assert (pm.sensor_type, pm.value, pm.units) == (SensorType.particulate, 7, "ug/m3")
    assert _th(pm) == (35, 150, 35)
    assert (detector.sensor_type, detector.value, detector.units, detector.edge_state) == (
        SensorType.combustible_gas, 0, "bool", EdgeState.normal)
    assert _th(detector) == (0.5, 1.0, 0.5)
    assert (presence.sensor_type, presence.value, presence.units) == (SensorType.radar_presence, 1, "persons_est")
    assert presence.thresholds is None and presence.edge_state == EdgeState.normal

    for p in ps.values():
        assert (p.epoch, p.seq, p.fw_version, p.location) == (1, 600000, "1.0.0", LOC)
        assert p.signal is not None and p.signal.rssi == -61


def test_device_grading_maps_to_edge_state():
    doc = air_doc(co={"ppm": 180, "state": "danger"}, gas={"adc": 1600, "state": "warning"},
                  presence={"detected": False})
    ps = _payloads(NodeKind.air, doc)
    assert ps["canary:co"].edge_state == EdgeState.alarm
    assert ps["canary:gas"].edge_state == EdgeState.warn
    assert ps["canary:particulate"].edge_state == EdgeState.normal
    assert ps["canary:presence"].value == 0


def test_gas_detector_contact_is_a_boolean_gas_reading():
    alarm = _payloads(NodeKind.air, air_doc(gas_detector={"alarm": True}))["canary:gas_detector"]
    assert (alarm.sensor_type, alarm.value, alarm.edge_state) == (SensorType.combustible_gas, 1, EdgeState.alarm)
    # firmware before 1.1.0 sends no gas_detector object; a malformed one is skipped
    for doc in (air_doc(gas_detector=None), air_doc(gas_detector={"alarm": 1}), air_doc(gas_detector=[])):
        assert "canary:gas_detector" not in _payloads(NodeKind.air, doc)


def test_warmup_fault_and_invalid_channels_produce_no_reading():
    doc = air_doc(co={"state": "warmup"}, gas={"state": "fault"}, particulate={"valid": False},
                  presence={"valid": False}, gas_detector=None)
    assert _payloads(NodeKind.air, doc) == {}
    # co graded but flagged invalid (no fresh frame) is skipped too
    assert "canary:co" not in _payloads(NodeKind.air, air_doc(co={"valid": False}))


def test_water_sample_and_states():
    ps = _payloads(NodeKind.water, WATER_SAMPLE, node_id="water-sensor")
    assert list(ps) == ["water-sensor:leak"]
    leak = ps["water-sensor:leak"]
    assert (leak.sensor_type, leak.value, leak.units, leak.edge_state) == (SensorType.water_leak, 0, "bool", EdgeState.normal)
    assert leak.thresholds is None  # water uses the backend defaults
    assert (leak.seq, leak.signal.rssi) == (123456, -58)

    wet = _payloads(NodeKind.water, water_doc(sensor={"state": "wet"}), node_id="w")["w:leak"]
    assert (wet.value, wet.edge_state) == (1, EdgeState.alarm)
    # latched but dry is a normal (clearing) reading; the latch is reported by the analysis
    latched = _payloads(NodeKind.water, water_doc(leak_latched=True), node_id="w")["w:leak"]
    assert (latched.value, latched.edge_state) == (0, EdgeState.normal)
    uninitialized = water_doc(sensor={"initialized": False, "state": "uninitialized"})
    assert _payloads(NodeKind.water, uninitialized, node_id="w") == {}


def test_kind_is_detected_by_shape():
    assert detect_kind(AIR_SAMPLE) == NodeKind.air
    assert detect_kind(WATER_SAMPLE) == NodeKind.water
    assert detect_kind("online") is None
    assert detect_kind({"error": "status_unavailable"}) is None
    assert detect_kind([AIR_SAMPLE]) is None
    assert detect_kind({"co": {}, "gas": {}, "particulate": 7}) is None


def test_node_id_slug():
    assert node_id_for("canary") == "canary"
    assert node_id_for("home/Air 1") == "home-air-1"
    assert node_id_for("--Weird__Base//") == "weird-base"
    assert node_id_for("///") == ""


def test_hostile_input_is_rejected_without_raising():
    assert parse_document(b"online") is None
    assert parse_document(b'{"uptime_ms": NaN}') is None
    assert parse_document(b'{"uptime_ms": Infinity}') is None
    assert parse_document(b"\xff\xfe\x00") is None
    assert parse_document(b"[" * 5000 + b"]" * 5000) is None  # nesting bomb
    assert parse_document(b'{"co": {"x": [[[[1]]]]}}') is None  # deeper than any firmware document
    assert parse_document(b'{"a": 1, "b": {"c": [1, 2]}}') == {"a": 1, "b": {"c": [1, 2]}}
    assert parse_document(b" " * 20000 + b"{}") is None  # oversized
    for bad in (True, -1, "12", 1.5, None, 2**64):
        assert uptime_ms({"uptime_ms": bad}) is None

    # wrong-typed fields never raise; the affected channel is simply skipped
    doc = air_doc(co={"ppm": "3"}, gas={"state": ["ok"]}, particulate={"warn_pm2_5": None},
                  presence={"detected": "yes"}, gas_detector={"alarm": "yes"})
    assert _payloads(NodeKind.air, doc) == {}
    assert "canary:co" not in _payloads(NodeKind.air, air_doc(co={"ppm": 1e400}))  # inf
    assert "canary:co" not in _payloads(NodeKind.air, air_doc(co={"ppm": 10**400}))  # overflows float
    assert "canary:co" not in _payloads(NodeKind.air, air_doc(co={"ppm": True}))
    assert _payloads(NodeKind.water, water_doc(sensor={"initialized": 1, "state": "wet"}), node_id="w") == {}


def test_only_explicitly_disabled_external_detector_is_skipped():
    doc = air_doc(gas_detector={"enabled": False, "alarm": True}, gas={"adc": 2300, "state": "danger"})
    payloads = _payloads(NodeKind.air, doc)
    assert "canary:gas_detector" not in payloads
    assert payloads["canary:gas"].edge_state == EdgeState.alarm
    for enabled in (True, None, 0, "false", [], {}):
        payload = _payloads(NodeKind.air, air_doc(gas_detector={"enabled": enabled, "alarm": True}))
        assert payload["canary:gas_detector"].edge_state == EdgeState.alarm
