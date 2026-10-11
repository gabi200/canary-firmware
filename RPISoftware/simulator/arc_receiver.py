"""Test receiver for the Canary escalation webhook (an ARC / 112 partner stand-in). Stdlib only.

Checks what a real partner must check, then logs the event and answers 200:
  * X-Canary-Timestamp within +-5 minutes of now (replay window);
  * X-Canary-Signature == sha256=<hex HMAC-SHA256(secret, timestamp + "." + raw body)>;
  * the body is canary.escalation.v1 JSON; X-Canary-Event repeats on retries (logged as duplicate).

    CANARY_ESCALATION_SECRET=... python arc_receiver.py [--port 8099] [--fail-first N]

--fail-first N answers 500 to the first N valid events, to watch the hub retry.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_SKEW_S = 300
MAX_BODY = 1 << 20


class Receiver(BaseHTTPRequestHandler):
    secret = b""
    fail_first = 0
    seen: set[str] = set()

    def _answer(self, code: int, message: str) -> None:
        body = json.dumps({"ok": code == 200, "message": message}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        if self.path.rstrip("/") != "/canary":
            return self._answer(404, "POST /canary")
        length = int(self.headers.get("Content-Length") or 0)
        if not 0 < length <= MAX_BODY:
            return self._answer(400, "missing or oversized body")
        raw = self.rfile.read(length)
        timestamp = self.headers.get("X-Canary-Timestamp", "")
        signature = self.headers.get("X-Canary-Signature", "")
        event_id = self.headers.get("X-Canary-Event", "")
        if not timestamp.isdigit() or abs(time.time() - int(timestamp)) > MAX_SKEW_S:
            return self._answer(401, "timestamp missing or outside +-5 min")
        expected = "sha256=" + hmac.new(self.secret, timestamp.encode() + b"." + raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return self._answer(401, "bad signature")
        try:
            event = json.loads(raw)
        except ValueError:
            return self._answer(400, "body is not JSON")
        if event.get("schema") != "canary.escalation.v1" or event.get("event_id") != event_id:
            return self._answer(400, "not a canary.escalation.v1 event")
        if Receiver.fail_first > 0:
            Receiver.fail_first -= 1
            print(f"[arc-sim] event {event_id}: answering 500 on purpose", flush=True)
            return self._answer(500, "simulated failure")
        duplicate = event_id in Receiver.seen
        Receiver.seen.add(event_id)
        incident = event.get("incident", {})
        print(f"[arc-sim] {'DUPLICATE ' if duplicate else ''}event {event_id}: incident {incident.get('id')} "
              f"-> {incident.get('state')} ({incident.get('hazard_type')}, {incident.get('severity')})", flush=True)
        print(json.dumps(event, indent=2, ensure_ascii=False), flush=True)
        return self._answer(200, "duplicate" if duplicate else "received")

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"[arc-sim] {self.address_string()} {fmt % args}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=int(os.environ.get("ARC_PORT", "8099")))
    parser.add_argument("--fail-first", type=int, default=0, help="answer 500 to the first N valid events")
    args = parser.parse_args()
    secret = os.environ.get("CANARY_ESCALATION_SECRET", "")
    if not secret:
        sys.exit("CANARY_ESCALATION_SECRET is not set (run scripts/pi_setup.sh; compose passes it from .env)")
    Receiver.secret, Receiver.fail_first = secret.encode(), args.fail_first
    print(f"[arc-sim] listening on :{args.port}/canary", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Receiver).serve_forever()


if __name__ == "__main__":
    main()
