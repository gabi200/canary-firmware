#!/usr/bin/env python3
"""Record an air sensor's status documents during a labelled experiment.

Polls the unauthenticated GET /api/status on the sensor directly, so no hub is
needed. Each run gets its own folder under air_sensor/recordings/:

  samples.jsonl  one line per poll: {"ts", "phase", "doc"} with the raw status
                 document, so it can be replayed through the hub's
                 parse_snapshot(ts, doc) without loss
  samples.csv    the same samples flattened (co.ppm, gas.adc, ...) for plotting
  events.jsonl   phase changes and notes typed during the run
  meta.json      label, host, firmware, notes, start and end times

Phases follow the shape the signature features expect: "baseline" until you
mark the event start, "event" until you mark its end, then "recovery".

While it runs, type a line and press Enter:
  s          event starts (for example, burner lit or gas valve opened)
  e          event ends (source removed, window opened)
  q          stop recording
  any text   saved as a timestamped note

Usage:
  python air_sensor/scripts/record_experiment.py cooking --host canary.local
  python air_sensor/scripts/record_experiment.py gas_leak --host 192.168.1.42 \\
      --baseline 300 --duration 1800 --note "butane lighter, 30 cm, kitchen"
"""
import argparse
import csv
import json
import queue
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# The hub classifier's labels (rules.LABELS) plus the two non-event windows the
# tests use. Other labels are allowed but flagged, to catch typos.
KNOWN_LABELS = (
    "normal", "humidity_only", "smouldering_fire", "flaming_fire",
    "gas_leak", "steam", "cooking", "aerosol",
)
RECORDINGS_DIR = Path(__file__).resolve().parent.parent / "recordings"


def fetch_status(host, timeout):
    url = host if host.startswith("http") else f"http://{host}"
    with urllib.request.urlopen(f"{url.rstrip('/')}/api/status", timeout=timeout) as response:
        return json.load(response)


def flatten(doc, prefix=""):
    flat = {}
    for key, value in doc.items():
        name = f"{prefix}{key}"
        if isinstance(value, dict):
            flat.update(flatten(value, f"{name}."))
        else:
            flat[name] = value
    return flat


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).astimezone().isoformat(timespec="milliseconds")


def read_commands(commands):
    for line in sys.stdin:
        commands.put(line.strip())
    commands.put("q")


def summary(doc):
    pm = doc.get("particulate", {})
    climate = doc.get("climate", {})
    return (
        f"CO {doc.get('co', {}).get('ppm', '?'):>4} ppm | "
        f"gas {doc.get('gas', {}).get('adc', '?'):>4} | "
        f"PM1/2.5/10 {pm.get('pm1_0', '?')}/{pm.get('pm2_5', '?')}/{pm.get('pm10', '?')} | "
        f"{climate.get('temperature_c', '?')} C {climate.get('humidity_percent', '?')} % | "
        f"detector {'ALARM' if doc.get('gas_detector', {}).get('alarm') else 'ok'} | "
        f"alarm {doc.get('alarm', {}).get('state', '?')}"
    )


def not_ready(doc):
    problems = []
    if doc.get("warmup_remaining_seconds", 0) > 0:
        problems.append(f"warm-up {doc['warmup_remaining_seconds']} s left")
    for section in ("co", "particulate", "climate", "presence"):
        if not doc.get(section, {}).get("valid", False):
            problems.append(f"{section} not reporting")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("label", help=f"experiment label, e.g. {', '.join(KNOWN_LABELS)}")
    parser.add_argument("--host", default="canary.local", help="sensor IP or mDNS name (default canary.local)")
    parser.add_argument("--interval", type=float, default=1.0, help="seconds between polls (default 1)")
    parser.add_argument("--baseline", type=float, default=0,
                        help="seconds of baseline to count down before prompting for the event (default 0)")
    parser.add_argument("--duration", type=float, default=0, help="stop after this many seconds (default: run until q)")
    parser.add_argument("--note", default="", help="free-text description saved in meta.json")
    parser.add_argument("--out", type=Path, default=RECORDINGS_DIR, help=f"output root (default {RECORDINGS_DIR})")
    args = parser.parse_args()

    if args.label not in KNOWN_LABELS:
        print(f"note: '{args.label}' is not one of the classifier labels ({', '.join(KNOWN_LABELS)})")

    try:
        first = fetch_status(args.host, timeout=5)
    except (urllib.error.URLError, OSError, ValueError) as error:
        sys.exit(f"cannot read http://{args.host}/api/status: {error}\n"
                 "Check the sensor is on the same network; if the .local name does not resolve, use its IP "
                 "(shown on the OLED or in the router's DHCP list).")
    problems = not_ready(first)
    if problems:
        print("warning: " + "; ".join(problems) + ". Readings before warm-up ends are not usable for training.")

    started = time.time()
    run_dir = args.out / f"{datetime.now().strftime('%Y%m%d-%H%M%S')}_{args.label}"
    run_dir.mkdir(parents=True, exist_ok=False)
    meta = {
        "label": args.label,
        "note": args.note,
        "host": args.host,
        "device": first.get("device", {}),
        "interval_s": args.interval,
        "started": iso(started),
        "started_ts": started,
    }
    columns = ["ts", "time", "phase"] + list(flatten(first))

    commands = queue.Queue()
    threading.Thread(target=read_commands, args=(commands,), daemon=True).start()
    print(f"recording '{args.label}' from {args.host} into {run_dir}")
    print("type s + Enter when the event starts, e when it ends, q to stop; any other text is saved as a note\n")

    phase = "baseline"
    samples = failures = 0
    baseline_prompted = args.baseline <= 0
    with open(run_dir / "samples.jsonl", "w", encoding="utf-8") as jsonl, \
            open(run_dir / "samples.csv", "w", encoding="utf-8", newline="") as csv_file, \
            open(run_dir / "events.jsonl", "w", encoding="utf-8") as events:
        writer = csv.DictWriter(csv_file, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()

        def log_event(kind, text=""):
            now = time.time()
            events.write(json.dumps({"ts": now, "time": iso(now), "kind": kind, "phase": phase, "text": text}) + "\n")
            events.flush()

        log_event("phase", phase)
        next_poll = time.monotonic()
        try:
            while True:
                stop = False
                while not commands.empty():
                    command = commands.get()
                    if command.lower() == "q":
                        stop = True
                    elif command.lower() == "s" and phase == "baseline":
                        phase = "event"
                        log_event("phase", phase)
                        print(">>> event started")
                    elif command.lower() == "e" and phase == "event":
                        phase = "recovery"
                        log_event("phase", phase)
                        print(">>> event ended, recording recovery")
                    elif command.lower() in ("s", "e"):
                        print(f"(ignored '{command}': already in {phase})")
                    elif command:
                        log_event("note", command)
                        print(f">>> note saved: {command}")
                elapsed = time.time() - started
                if stop or (args.duration and elapsed >= args.duration):
                    break
                if not baseline_prompted and elapsed >= args.baseline:
                    baseline_prompted = True
                    print(f"\a>>> {args.baseline:.0f} s of baseline recorded: start the event and type s")

                try:
                    doc = fetch_status(args.host, timeout=max(args.interval, 2))
                except (urllib.error.URLError, OSError, ValueError) as error:
                    failures += 1
                    log_event("poll_error", str(error))
                    print(f"poll failed ({error}); retrying")
                else:
                    now = time.time()
                    jsonl.write(json.dumps({"ts": now, "phase": phase, "doc": doc}) + "\n")
                    jsonl.flush()
                    writer.writerow({"ts": f"{now:.3f}", "time": iso(now), "phase": phase, **flatten(doc)})
                    csv_file.flush()
                    samples += 1
                    print(f"[{elapsed:7.1f}s {phase:>8}] {summary(doc)}")

                next_poll += args.interval
                time.sleep(max(0.0, next_poll - time.monotonic()))
        except KeyboardInterrupt:
            pass
        log_event("stop")

    ended = time.time()
    meta.update(ended=iso(ended), ended_ts=ended, duration_s=round(ended - started, 1),
                samples=samples, poll_failures=failures)
    (run_dir / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    print(f"\nsaved {samples} samples ({failures} failed polls) over {ended - started:.0f} s to {run_dir}")


if __name__ == "__main__":
    main()
