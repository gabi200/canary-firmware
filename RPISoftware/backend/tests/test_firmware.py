"""Firmware: version history from status documents, pinned push targets, pushes to a fake device's
/api/ota (a real local TCP server), confirmation on reboot, refusals and roles."""

from __future__ import annotations

import asyncio
import json

import pytest
from sqlalchemy import select

from app import firmware
from app.db import SessionLocal
from app.ingestion import hardware
from app.ingestion.hardware import handle_hardware_message
from app.models import AuditLogEntry, NodeOtaTarget
from app.realtime.ws import manager
from tests.conftest import auth_token
from tests.hardware_docs import air_doc, water_doc


def image(chip_id: int = 9, size: int = 4096) -> bytes:
    """A minimal ESP32 application image: header magic + chip id, app description magic at 32."""
    data = bytearray(size)
    data[0] = 0xE9
    data[12:14] = chip_id.to_bytes(2, "little")
    data[32:36] = (0xABCD5432).to_bytes(4, "little")
    for i in range(64, size):
        data[i] = i % 251
    return bytes(data)


class FakeDevice:
    """The firmware's /api/ota: refuses a bad token right after the headers (and closes without
    reading the body), else reads the whole multipart body and answers like the firmware."""

    def __init__(self, token: str = "device-token-123", answer: tuple[int, dict] | None = None) -> None:
        self.token, self.answer = token, answer
        self.requests: list[tuple[dict[str, str], bytes]] = []
        self.server: asyncio.base_events.Server | None = None

    async def start(self) -> str:
        self.server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        return f"127.0.0.1:{self.server.sockets[0].getsockname()[1]}"

    async def stop(self) -> None:
        self.server.close()
        await self.server.wait_closed()

    async def _reply(self, writer, code: int, doc: dict) -> None:
        body = json.dumps(doc).encode()
        writer.write(f"HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n"
                     "Connection: close\r\n\r\n".encode() + body)
        await writer.drain()
        writer.close()

    async def _serve(self, reader, writer) -> None:
        lines = (await reader.readuntil(b"\r\n\r\n")).decode().split("\r\n")
        headers = {k.lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:] if line)}
        if headers.get("authorization") != f"Bearer {self.token}":
            await self._reply(writer, 401, {"error": "unauthorized", "message": "Bearer authentication required"})
            return
        body = await reader.readexactly(int(headers["content-length"]))
        self.requests.append((headers, body))
        code, doc = self.answer or (200, {"ok": True, "rebooting": True})
        await self._reply(writer, code, doc)


@pytest.fixture(autouse=True)
def _fresh(monkeypatch):
    hardware.reset_state()
    events: list[dict] = []

    async def capture(building_id: str, message: dict) -> None:
        events.append(message)

    monkeypatch.setattr(manager, "broadcast", capture)
    yield events
    hardware.reset_state()


async def _hdr(client, user: str) -> dict:
    return {"Authorization": f"Bearer {await auth_token(client, user)}"}


async def _status(base: str, doc: dict) -> None:
    await handle_hardware_message(f"{base}/status", json.dumps(doc).encode())


async def _pin(client, node: str, address: str, token: str = "device-token-123", user: str = "tehnician"):
    return await client.put(f"/api/v1/admin/nodes/{node}/ota-target", json={"address": address, "token": token},
                            headers=await _hdr(client, user))


async def _push(client, node: str, data: bytes, user: str = "tehnician", name: str = "air_sensor.ino.bin"):
    return await client.post(f"/api/v1/admin/nodes/{node}/firmware", files={"firmware": (name, data)},
                             headers=await _hdr(client, user))


async def _detail(client, node: str) -> dict:
    resp = await client.get(f"/api/v1/admin/nodes/{node}/firmware", headers=await _hdr(client, "admin"))
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_check_image_accepts_only_application_images_for_the_node_chip():
    firmware.check_image("air", image(9))
    firmware.check_image("water", image(5))
    with pytest.raises(firmware.ImageRejected, match="another chip"):
        firmware.check_image("water", image(9))
    with pytest.raises(firmware.ImageRejected, match="not an ESP32"):
        firmware.check_image("air", b"PK\x03\x04" + bytes(100))
    no_desc = bytearray(image(9))
    no_desc[32:36] = bytes(4)
    with pytest.raises(firmware.ImageRejected, match="application"):
        firmware.check_image("air", bytes(no_desc))
    assert firmware.safe_filename('../x"\r\nEvil: 1.BIN') == "x_Evil_1.bin"
    assert firmware.safe_filename(None) == "firmware.bin"


async def test_versions_are_recorded_once_per_change(client):
    await _status("canary", air_doc(1000))
    await _status("canary", air_doc(2000))
    await _status("canary", air_doc(3000, device={"firmware": "1.1.0"}, wifi={"ip": "192.168.1.40"}))
    detail = await _detail(client, "canary")
    assert [h["firmware"] for h in detail["history"]] == ["1.1.0", "1.0.0"]
    assert (detail["firmware"], detail["reported_ip"], detail["address"]) == ("1.1.0", "192.168.1.40", None)
    assert (detail["token_set"], detail["blocked"]) == (False, "no_target")


async def test_target_is_pinned_by_maintainers_and_the_token_never_leaves(client):
    await _status("canary", air_doc(1000))
    assert (await _pin(client, "canary", "192.168.1.40", user="mihai")).status_code == 403
    no_token = await client.put("/api/v1/admin/nodes/canary/ota-target", json={"address": "192.168.1.40"},
                                headers=await _hdr(client, "tehnician"))
    assert no_token.status_code == 422
    assert (await _pin(client, "canary", "192.168.1.400")).status_code == 422
    assert (await _pin(client, "canary", "evil.example:80")).status_code == 422
    assert (await _pin(client, "canary", "192.168.1.40", token="short")).status_code == 422
    assert (await _pin(client, "canary", "192.168.1.40", token="abc\r\ndef-ghijkl")).status_code == 422
    resp = await _pin(client, "canary", "192.168.1.40")
    assert resp.status_code == 200, resp.text
    assert (resp.json()["address"], resp.json()["token_set"], resp.json()["blocked"]) == ("192.168.1.40", True, None)
    assert "device-token-123" not in resp.text
    async with SessionLocal() as s:
        target = await s.get(NodeOtaTarget, "canary")
        assert "device-token-123" not in target.token_enc
        audits = (await s.scalars(select(AuditLogEntry).where(AuditLogEntry.action == "ota_target_set"))).all()
        assert [a.detail for a in audits] == [{"fields": ["address", "token"]}]
    listed = await client.get("/api/v1/admin/buildings/bld_007/firmware", headers=await _hdr(client, "mihai"))
    assert listed.status_code == 200 and "device-token-123" not in listed.text
    assert [n["node_id"] for n in listed.json()] == ["canary"]
    moved = await client.put("/api/v1/admin/nodes/canary/ota-target", json={"address": "192.168.1.41"},
                             headers=await _hdr(client, "tehnician"))
    assert (moved.status_code, moved.json()["address"], moved.json()["token_set"]) == (200, "192.168.1.41", True)
    gone = await client.delete("/api/v1/admin/nodes/canary/ota-target", headers=await _hdr(client, "tehnician"))
    assert gone.status_code == 204
    assert (await _detail(client, "canary"))["token_set"] is False


async def test_push_streams_the_image_and_the_reboot_confirms_it(client, _fresh):
    await _status("canary", air_doc(500_000))
    device = FakeDevice()
    address = await device.start()
    try:
        assert (await _pin(client, "canary", address)).status_code == 200
        data = image(9, 200_000)
        resp = await _push(client, "canary", data)
        assert resp.status_code == 202, resp.text
        job = resp.json()
        assert (job["status"], job["firmware_before"], job["filename"]) == ("queued", "1.0.0", "air_sensor.ino.bin")
    finally:
        await device.stop()

    [(headers, body)] = device.requests
    assert headers["content-type"].startswith("multipart/form-data; boundary=")
    boundary = headers["content-type"].split("boundary=")[1]
    head, _, rest = body.partition(b"\r\n\r\n")
    assert head == (f'--{boundary}\r\nContent-Disposition: form-data; name="firmware"; '
                    f'filename="air_sensor.ino.bin"\r\nContent-Type: application/octet-stream').encode()
    assert rest == data + f"\r\n--{boundary}--\r\n".encode()

    detail = await _detail(client, "canary")
    assert (detail["last_update"]["status"], detail["blocked"]) == ("flashed", "busy")
    assert (await _push(client, "canary", image(9))).status_code == 409  # one pending push per node

    await _status("canary", air_doc(1_000, device={"firmware": "1.1.0"}))  # rebooted into the new image
    detail = await _detail(client, "canary")
    [update] = detail["updates"]
    assert (update["status"], update["firmware_after"], update["requested_by_name"]) == (
        "confirmed", "1.1.0", "Tehnician Canary")
    assert detail["blocked"] is None
    statuses = [e["status"] for e in _fresh if e["type"] == "firmware_update"]
    assert statuses == ["uploading", "flashed", "confirmed"]


async def test_device_refusals_are_recorded_with_their_reason(client):
    await _status("canary", air_doc(1000))
    device = FakeDevice(token="another-token-456")  # refuses before reading the 1 MB body
    address = await device.start()
    try:
        await _pin(client, "canary", address)
        assert (await _push(client, "canary", image(9, 1_000_000))).status_code == 202
        assert (await _detail(client, "canary"))["last_update"]["status"] == "failed"
        assert (await _detail(client, "canary"))["last_update"]["detail"] == "unauthorized"

        device.token = "device-token-123"
        device.answer = (500, {"error": "ota_failed", "message": "Firmware image is invalid"})
        assert (await _push(client, "canary", image(9))).status_code == 202
        assert (await _detail(client, "canary"))["last_update"]["detail"] == "ota_failed: Firmware image is invalid"
    finally:
        await device.stop()

    assert (await _push(client, "canary", image(9))).status_code == 202  # nothing listens any more
    last = (await _detail(client, "canary"))["last_update"]
    assert last["status"] == "failed" and "Connection" in last["detail"]


async def test_push_refusals(client):
    await _status("canary", air_doc(1000))
    await _status("water-sensor", water_doc(1000))
    assert (await _push(client, "canary", image(9))).status_code == 409  # no target
    await _pin(client, "canary", "127.0.0.1:9")
    await _pin(client, "water-sensor", "127.0.0.1:9")
    assert (await _push(client, "canary", image(9), user="mihai")).status_code == 403
    assert (await _push(client, "water-sensor", image(9))).status_code == 422  # S3 image on a C3
    assert (await _push(client, "canary", b"\xe9" + bytes(10))).status_code == 422
    big = image(9, firmware.MAX_IMAGE_BYTES + 1)
    assert (await _push(client, "canary", big)).status_code == 413
    await _status("canary", air_doc(2000, ota={"in_progress": True}))  # someone uses the browser page
    resp = await _push(client, "canary", image(9))
    assert (resp.status_code, resp.json()["detail"]) == (409, "ota_active")
    await handle_hardware_message("canary/availability", b"offline")
    resp = await _push(client, "canary", image(9))
    assert (resp.status_code, resp.json()["detail"]) == (409, "offline")
    assert (await client.get("/api/v1/admin/nodes/nope/firmware", headers=await _hdr(client, "admin"))).status_code == 404


async def test_deleting_a_node_drops_its_target(client):
    await _status("canary", air_doc(1000))
    await _pin(client, "canary", "192.168.1.40")
    await handle_hardware_message("canary/availability", b"offline")
    resp = await client.delete("/api/v1/admin/nodes/canary", headers=await _hdr(client, "tehnician"))
    assert resp.status_code == 204, resp.text
    async with SessionLocal() as s:
        assert await s.get(NodeOtaTarget, "canary") is None
