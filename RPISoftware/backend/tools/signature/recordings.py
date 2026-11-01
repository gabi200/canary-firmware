"""Train the shadow signature model on labelled air-node recordings plus synthetic windows.

Recordings come from air_sensor/scripts/record_experiment.py: one directory per run with
meta.json (the label) and samples.jsonl (1 Hz status documents tagged baseline / event /
recovery). Each run is cut into hub-shaped windows (one document per 15 s, up to 600 s):
windows that end before the event are `normal`, windows covering at least
EVENT_LEAD_S of the event take the run's label, and the ones in between are skipped.
Real runs are few and their windows overlap heavily, so they are mixed with the
synthetic set (which also keeps every class present) and scored by leaving one whole
recording out at a time, never by a random window split.

Run from RPISoftware/backend with the train extra installed:
    python -m tools.signature.recordings                      # evaluate only
    python -m tools.signature.recordings --map smoke=smouldering_fire --out model.json
Writing over app/analytics/signature/signature_model_v1.json changes the hub's shadow
prediction only; no decision reads it.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.tree import DecisionTreeClassifier

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures, extract_features, parse_snapshot
from app.analytics.signature.rules import assess
from tools.signature.synth import CLASSES, generate
from tools.signature.train import export, to_matrix

DEFAULT_ROOT = Path(__file__).resolve().parents[4] / "air_sensor" / "recordings"
STEP_S = 15.0
WINDOW_S = 600.0
MIN_SPAN_S = 180.0
EVENT_LEAD_S = 30.0
# An event whose largest channel rise stays under this (in multiples of warn, the rules'
# quiet level) taught the sensor nothing; training on it would teach "label == normal".
FLAT_RISE = 0.3
# Recording labels with an obvious class; anything else needs --map.
DEFAULT_MAP = {"natural_gas": "gas_leak", "lpg": "gas_leak"}
_GRADED = ("co", "gas", "particulate")


@dataclass(frozen=True)
class Recording:
    name: str
    label: str
    snapshots: list  # AirSnapshot, resampled to STEP_S
    event_start: float
    event_end: float
    resets: int  # device reboots seen as uptime going backwards


@dataclass(frozen=True)
class Window:
    recording: str
    label: str
    features: SignatureFeatures


def load_recording(path: Path, *, keep_warmup: bool = False) -> Recording | None:
    """None when the run has no event phase. keep_warmup reads channels the device marked
    `warmup` (after a reboot mid-run) as live; the hub itself never does."""
    meta = json.loads((path / "meta.json").read_text(encoding="utf-8"))
    rows = []
    with open(path / "samples.jsonl", encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    event = [r["ts"] for r in rows if r.get("phase") == "event"]
    if not rows or not event:
        return None
    rows.sort(key=lambda r: r["ts"])
    uptimes = [r["doc"].get("uptime_ms") for r in rows]
    resets = sum(1 for a, b in zip(uptimes, uptimes[1:])
                 if isinstance(a, int) and isinstance(b, int) and b < a)
    if keep_warmup:
        rows = [{**r, "doc": _without_warmup(r["doc"])} for r in rows]
    return Recording(path.name, str(meta.get("label", "")), resample(rows), min(event), max(event), resets)


def _without_warmup(doc: dict) -> dict:
    out = dict(doc)
    for section in _GRADED:
        obj = out.get(section)
        if isinstance(obj, dict) and obj.get("state") == "warmup":
            out[section] = {**obj, "state": "ok"}
    return out


def resample(rows: Sequence[dict]) -> list:
    """The first sample at or after each STEP_S tick, matching the hub's heartbeat cadence."""
    out = []
    next_t = rows[0]["ts"]
    for r in rows:
        if r["ts"] >= next_t:
            out.append(parse_snapshot(r["ts"], r["doc"]))
            next_t = r["ts"] + STEP_S
    return out


def windows_for(rec: Recording, label: str) -> list[Window]:
    out = []
    for i, end in enumerate(s.ts for s in rec.snapshots):
        snaps = [s for s in rec.snapshots[: i + 1] if s.ts >= end - WINDOW_S]
        if snaps[-1].ts - snaps[0].ts < MIN_SPAN_S:
            continue
        if end < rec.event_start:
            out.append(Window(rec.name, "normal", extract_features(snaps)))
        elif end >= rec.event_start + EVENT_LEAD_S and snaps[0].ts <= rec.event_end:
            out.append(Window(rec.name, label, extract_features(snaps)))
    return out


def max_rise(f: SignatureFeatures) -> float:
    rises = [f.rise_co, f.rise_gas, f.rise_pm2_5, f.rise_pm10]
    return max((r for r in rises if r is not None), default=0.0)


def build_model(kind: str, *, trees: int, max_depth: int, seed: int):
    if kind == "tree":
        return DecisionTreeClassifier(max_depth=max_depth, random_state=seed)
    return RandomForestClassifier(n_estimators=trees, max_depth=max_depth, random_state=seed)


def fit(kind: str, synthetic: Sequence[tuple[str, SignatureFeatures]], real: Sequence[Window], *,
        real_weight: float, trees: int, max_depth: int, seed: int):
    feats = [f for _, f in synthetic] + [w.features for w in real]
    labels = [label for label, _ in synthetic] + [w.label for w in real]
    weights = [1.0] * len(synthetic) + [real_weight] * len(real)
    clf = build_model(kind, trees=trees, max_depth=max_depth, seed=seed)
    clf.fit(to_matrix(feats), np.array(labels), sample_weight=np.array(weights))
    return clf


def parse_map(pairs: Sequence[str]) -> dict[str, str]:
    out = {}
    for pair in pairs:
        name, sep, target = pair.partition("=")
        if not sep or target not in CLASSES:
            raise SystemExit(f"--map {pair!r}: expected LABEL=CLASS with CLASS in {', '.join(CLASSES)}")
        out[name] = target
    return out


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Train the shadow signature model on recordings + synthetic windows.")
    parser.add_argument("recordings", nargs="*", type=Path,
                        help=f"recording directories, or a folder of them (default {DEFAULT_ROOT})")
    parser.add_argument("--map", action="append", default=[], metavar="LABEL=CLASS",
                        help="train a recording label as one of the model's classes, e.g. smoke=smouldering_fire")
    parser.add_argument("--model", choices=("forest", "tree"), default="forest")
    parser.add_argument("--trees", type=int, default=40)
    parser.add_argument("--max-depth", type=int, default=6)
    parser.add_argument("--synthetic-per-class", type=int, default=400)
    parser.add_argument("--real-weight", type=float, default=5.0,
                        help="sample weight of each real window relative to a synthetic one")
    parser.add_argument("--keep-flat", action="store_true", help="also train on events that show no response")
    parser.add_argument("--keep-warmup", action="store_true",
                        help="use samples taken in warm-up after a mid-run reboot (the hub ignores them live)")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", type=Path, help="write the exported model here (default: evaluate only)")
    args = parser.parse_args(argv)

    label_map = {**DEFAULT_MAP, **parse_map(args.map)}
    paths = args.recordings or [DEFAULT_ROOT]
    dirs: list[Path] = []
    for p in paths:
        is_run = (p / "meta.json").exists()
        children = [] if is_run else sorted(c for c in p.iterdir() if c.is_dir())
        for c in children:
            if not (c / "meta.json").exists():
                print(f"skip {c.name}: no meta.json (still recording?)")
        dirs.extend([p] if is_run else [c for c in children if (c / "meta.json").exists()])

    real: list[Window] = []
    for d in dirs:
        rec = load_recording(d, keep_warmup=args.keep_warmup)
        if rec is None:
            print(f"skip {d.name}: no event phase")
            continue
        label = label_map.get(rec.label, rec.label)
        if label not in CLASSES:
            print(f"skip {d.name}: label {rec.label!r} is not a class; pass --map {rec.label}=<class>")
            continue
        windows = windows_for(rec, label)
        event = [w for w in windows if w.label == label]
        if not event:
            print(f"skip {d.name}: no window covers the event")
            continue
        rise = max(max_rise(w.features) for w in event)
        flat = rise < FLAT_RISE and label != "normal"
        counts = Counter(w.label for w in windows)
        note = " FLAT: no clear response" + ("" if args.keep_flat else ", left out (--keep-flat keeps it)")
        print(f"{d.name}: {dict(counts)}  peak rise {rise:.2f}x warn{note if flat else ''}")
        if rec.resets:
            print(f"  device rebooted {rec.resets}x during the run"
                  + ("; warm-up samples kept" if args.keep_warmup else "; warm-up samples dropped (--keep-warmup)"))
        if flat and not args.keep_flat:
            continue
        real.extend(windows)

    synthetic = [(label, extract_features(s)) for label, s in
                 generate(seed=args.seed, n_per_class=args.synthetic_per_class)]
    opts = dict(real_weight=args.real_weight, trees=args.trees, max_depth=args.max_depth, seed=args.seed)

    names = sorted({w.recording for w in real})
    if names:
        print("\nleave-one-recording-out (trained on synthetic + the other recordings):")
        print("  synthetic-only shown for comparison; rules = the hub's rule-based label")
    for name in names:
        held = [w for w in real if w.recording == name]
        rest = [w for w in real if w.recording != name]
        x = to_matrix([w.features for w in held])
        with_real = list(fit(args.model, synthetic, rest, **opts).predict(x))
        synth_only = list(fit(args.model, synthetic, [], **opts).predict(x))
        rules = [assess(w.features).label for w in held]
        truth = [w.label for w in held]
        for title, pred in (("model", with_real), ("synthetic-only", synth_only), ("rules", rules)):
            hits = sum(p == t for p, t in zip(pred, truth))
            wrong = Counter(f"{t}->{p}" for p, t in zip(pred, truth) if p != t)
            print(f"  {name:28s} {title:15s} {hits:3d}/{len(truth):<3d} {dict(wrong.most_common(3)) or ''}")

    clf = fit(args.model, synthetic, real, **opts)
    importances = sorted(zip(FEATURE_NAMES, clf.feature_importances_), key=lambda kv: -kv[1])[:8]
    print("\ntop features: " + ", ".join(f"{n} {v:.2f}" for n, v in importances))
    print(f"trained {args.model} on {len(synthetic)} synthetic + {len(real)} real windows")
    if args.out:
        args.out.write_text(json.dumps(export(clf), separators=(",", ":")) + "\n", encoding="utf-8")
        print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
