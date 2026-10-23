"""Firmware: the version each node runs, and pushes from the dashboard to a node's `/api/ota`.

Versions: every status document carries `device.firmware`; the first document with a new value
adds a NodeFirmwareSeen row (hardware ingestion).

Pushes: staff pin the device's HTTP address and API token (NodeOtaTarget, the token sealed under
CANARY_CARE_KEY). The address is never taken from MQTT unchecked: anything on the broker can
publish a status document, and the hub would hand the token to whatever address it names; the
reported `wifi.ip` is only a suggestion. A push checks the image (an ESP32 application image for
the node's chip), then streams it the way the device's own update page does (multipart field
`firmware`, a .bin filename, Content-Length), one push at a time per hub process. The device
answers `{"ok":true,"rebooting":true}` (flashed) or `{"error","message"}` (failed); its first live
status document after the reboot confirms the job. The device's hazard alarm keeps running
through an update (firmware README, "Web OTA").
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import secrets
import select as io_select
import socket
from collections.abc import Iterable, Sequence
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.care.service import cipher
from app.db import SessionLocal
from app.enums import NodeKind
from app.models import FirmwareUpdate, Node, NodeOtaTarget, User
from app.realtime.ws import manager
from app.schemas import FirmwareUpdateOut

log = logging.getLogger("canary.firmware")

MAX_IMAGE_BYTES = 4 * 1024 * 1024  # the largest OTA slot of the default partition schemes is ~3.3 MB
# ESP-IDF image header: magic 0xE9, chip id (uint16 LE) at byte 12; the application description
# (esp_app_desc_t, magic 0xABCD5432) opens the first segment, at byte 32.
_IMAGE_MAGIC = 0xE9
_APP_DESC_MAGIC = 0xABCD5432
_CHIPS = {NodeKind.air: (9, "ESP32-S3"), NodeKind.water: (5, "ESP32-C3")}

DEVICE_PORT = 80
CONNECT_TIMEOUT_S = 5.0
SEND_TIMEOUT_S = 30.0  # per chunk: the device reads while it writes flash
ANSWER_TIMEOUT_S = 60.0  # after the last byte: it finishes the image and answers
_CHUNK = 4096

QUEUE_TIMEOUT = timedelta(minutes=15)  # queued / uploading without an end: the hub process died
REBOOT_TIMEOUT = timedelta(minutes=5)  # flashed, and no status document since the reboot
CONFIRM_WINDOW = timedelta(minutes=30)  # a late reboot still confirms
PENDING = ("queued", "uploading", "flashed")

_lock = asyncio.Lock()


class ImageRejected(ValueError):
    """Not a firmware image this node can run (-> 422)."""


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------- #
# Images
# --------------------------------------------------------------------------- #
def check_image(kind: str, image: bytes) -> None:
    """Raise ImageRejected unless `image` is an ESP32 application image for this node kind's chip."""
    if len(image) < 64 or image[0] != _IMAGE_MAGIC:
        raise ImageRejected("not an ESP32 firmware image (.bin from the Arduino build)")
    chip_id, chip = _CHIPS[NodeKind(kind)]
    found = int.from_bytes(image[12:14], "little")
    if found != chip_id:
        raise ImageRejected(f"the image is for another chip (id {found}); {kind} nodes are {chip}")
    if int.from_bytes(image[32:36], "little") != _APP_DESC_MAGIC:
        raise ImageRejected("not an application image (a merged, bootloader or partition .bin?)")


def safe_filename(name: str | None) -> str:
    """The upload's name as the device accepts it: [A-Za-z0-9._-], <= 64 chars, ending in .bin."""
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", (name or "").rsplit("/", 1)[-1])
    stem = stem[:-4] if stem.lower().endswith(".bin") else stem
    return (stem.strip("._")[:60] or "firmware") + ".bin"


# --------------------------------------------------------------------------- #
# Push targets
# --------------------------------------------------------------------------- #
def seal_token(token: str) -> str:
    """Raises app.care.service.CareUnavailable without a usable CANARY_CARE_KEY."""
    return cipher().encrypt(token.encode()).decode()


def reported_ip(node: Node) -> str | None:
    """`wifi.ip` of the latest status document: a suggestion for the pinned address, never used as is."""
    wifi = (node.last_status or {}).get("wifi")
    ip = wifi.get("ip") if isinstance(wifi, dict) else None
    return ip if isinstance(ip, str) and re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip) else None


def ota_active(node: Node) -> bool:
    ota = (node.last_status or {}).get("ota")
    return isinstance(ota, dict) and ota.get("in_progress") is True


# --------------------------------------------------------------------------- #
# Jobs
# --------------------------------------------------------------------------- #
def status_of(job: FirmwareUpdate, now: datetime | None = None) -> str:
    now = now or _now()
    if job.status in ("queued", "uploading") and now - job.created_ts > QUEUE_TIMEOUT:
        return "timeout"
    if job.status == "flashed" and job.flashed_ts and now - job.flashed_ts > REBOOT_TIMEOUT:
        return "timeout"
    return job.status


def blocked(node: Node, target: NodeOtaTarget | None, last: FirmwareUpdate | None, now: datetime) -> str | None:
    """Why a push to this node would be refused now, or None."""
    if last is not None and status_of(last, now) in PENDING:
        return "busy"
    if not node.online:
        return "offline"
    if target is None:
        return "no_target"
    if ota_active(node):
        return "ota_active"
    return None


async def outs(session: AsyncSession, jobs: Sequence[FirmwareUpdate]) -> list[FirmwareUpdateOut]:
    ids = {j.requested_by_user_id for j in jobs}
    names = {u.id: u.display_name or u.username for u in await session.scalars(select(User).where(User.id.in_(ids)))}
    now = _now()
    return [
        FirmwareUpdateOut(
            update_id=j.id, node_id=j.node_id, filename=j.filename, size=j.size, sha256=j.sha256,
            firmware_before=j.firmware_before, firmware_after=j.firmware_after, status=status_of(j, now),
            detail=j.detail, requested_by_name=names.get(j.requested_by_user_id), created_ts=j.created_ts,
            finished_ts=j.finished_ts,
        )
        for j in jobs
    ]


async def _broadcast(job: FirmwareUpdate) -> None:
    try:
        await manager.broadcast(job.building_id, {
            "type": "firmware_update", "building_id": job.building_id, "node_id": job.node_id,
            "update_id": job.id, "status": job.status, "detail": job.detail,
            "firmware_after": job.firmware_after, "ts": _iso(_now()),
        })
    except Exception:  # noqa: BLE001 - best-effort
        log.exception("firmware event broadcast failed for %s", job.id)


async def _finish(job_id: str, status: str, detail: str | None) -> FirmwareUpdate | None:
    async with SessionLocal() as session:
        job = await session.get(FirmwareUpdate, job_id)
        if job is None:
            return None
        job.status, job.detail = status, detail
        if status == "flashed":
            job.flashed_ts = _now()
        elif status != "uploading":
            job.finished_ts = _now()
        await session.commit()
    await _broadcast(job)
    return job


async def run(job_id: str, image: bytes) -> None:
    """Push one queued job's image to its node. Never raises."""
    try:
        async with _lock:
            async with SessionLocal() as session:
                job = await session.get(FirmwareUpdate, job_id)
                target = await session.get(NodeOtaTarget, job.node_id) if job else None
                if job is None:
                    return
                if target is None:
                    await _finish(job_id, "failed", "no_target")
                    return
                address, token = target.address, cipher().decrypt(target.token_enc.encode()).decode()
                filename = job.filename
            await _finish(job_id, "uploading", None)
            code, error = await upload(address, token, filename, image)
            await _finish(job_id, "flashed" if code == 200 else "failed", error)
            log.info("firmware push %s to %s: %s", job_id, address, "flashed" if code == 200 else error)
    except asyncio.CancelledError:
        raise
    except Exception:  # noqa: BLE001
        log.exception("firmware push %s crashed", job_id)
        try:
            await _finish(job_id, "failed", "hub_error")
        except Exception:  # noqa: BLE001
            log.exception("could not record the failed push %s", job_id)


async def confirm_reboot(node: Node, now: datetime) -> None:
    """The first live status document after a reboot: the node's flashed push is confirmed with the
    version it now reports. Never raises."""
    try:
        async with SessionLocal() as session:
            job = await session.scalar(
                select(FirmwareUpdate)
                .where(FirmwareUpdate.node_id == node.id, FirmwareUpdate.status == "flashed",
                       FirmwareUpdate.flashed_ts >= now - CONFIRM_WINDOW)
                .order_by(FirmwareUpdate.created_ts.desc()).limit(1)
            )
            if job is None:
                return
            job.status, job.firmware_after, job.finished_ts = "confirmed", node.firmware, now
            await session.commit()
        await _broadcast(job)
    except Exception:  # noqa: BLE001 - must never break ingestion
        log.exception("firmware confirmation failed for %s", node.id)


# --------------------------------------------------------------------------- #
# The device's /api/ota
# --------------------------------------------------------------------------- #
def _describe(exc: BaseException) -> str:
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return "timeout"
    return f"{type(exc).__name__}: {exc}"[:200]


def _answer(raw: bytes) -> tuple[int | None, str | None]:
    head, _, body = raw.partition(b"\r\n\r\n")
    m = re.match(rb"HTTP/1\.[01] (\d{3})", head)
    if m is None:
        return None, "no_answer" if not raw else "bad_answer"
    code = int(m.group(1))
    if code == 200:
        return code, None
    try:
        doc = json.loads(body)
    except ValueError:
        doc = None
    error = doc.get("error") if isinstance(doc, dict) else None
    message = doc.get("message") if isinstance(doc, dict) else None
    if not isinstance(error, str) or not error:
        return code, f"http_{code}"
    # ota_failed carries the reason only in its message (e.g. "Malformed multipart firmware upload")
    detail = f"{error}: {message}" if error == "ota_failed" and isinstance(message, str) else error
    return code, "".join(ch for ch in detail if ch.isprintable())[:200]


def _exchange(host: str, port: int, parts: Iterable[bytes | memoryview]) -> bytes:
    """Send the request part by part on a blocking socket and return the device's answer. Before
    each part it checks for an early answer (a refusal right after the headers); after a reset
    mid-upload it still reads what arrived before it."""
    answer = bytearray()
    with socket.create_connection((host, port), timeout=CONNECT_TIMEOUT_S) as sock:
        sock.settimeout(SEND_TIMEOUT_S)
        try:
            for part in parts:
                if io_select.select([sock], [], [], 0)[0]:
                    break  # answered (or closed) before the upload ended: a refusal
                sock.sendall(part)
        except OSError:
            pass  # reset or stalled mid-upload: whatever it answered says why
        sock.settimeout(ANSWER_TIMEOUT_S)
        try:
            while len(answer) < 16 * 1024 and (data := sock.recv(4096)):
                answer += data  # until the device closes (Connection: close)
        except OSError:
            if not answer:
                raise
    return bytes(answer)


async def upload(address: str, token: str, filename: str, image: bytes) -> tuple[int | None, str | None]:
    """POST `image` to http://<address>/api/ota like the device's update page: (HTTP status, None) on
    success, else (status or None, error)."""
    host, _, port = address.partition(":")
    boundary = f"canary-{secrets.token_hex(16)}"
    head = (f'--{boundary}\r\nContent-Disposition: form-data; name="firmware"; filename="{filename}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n").encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    request = (f"POST /api/ota HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {token}\r\n"
               f"Content-Type: multipart/form-data; boundary={boundary}\r\n"
               f"Content-Length: {len(head) + len(image) + len(tail)}\r\nConnection: close\r\n\r\n").encode()
    body = memoryview(image)
    parts = (request, head, *(body[i:i + _CHUNK] for i in range(0, len(body), _CHUNK)), tail)
    try:
        raw = await asyncio.to_thread(_exchange, host, int(port or DEVICE_PORT), parts)
    except OSError as exc:  # refused, unreachable, timeout
        return None, _describe(exc)
    return _answer(raw)
