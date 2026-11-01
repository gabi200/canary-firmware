"""Training on labelled recordings: windowing, reboot handling and the model export."""

from __future__ import annotations

import json

import pytest

pytest.importorskip("sklearn")

from app.analytics.signature.model import forest_from_dict, probabilities  # noqa: E402
from tests.hardware_docs import air_doc  # noqa: E402
from tools.signature import recordings  # noqa: E402
from tools.signature.recordings import build_model, load_recording, windows_for  # noqa: E402
from tools.signature.train import export, to_matrix  # noqa: E402

EVENT_AT = 300


def write_run(path, label="aerosol", seconds=600, reboot_at=None, pm_rise=60):
    path.mkdir()
    (path / "meta.json").write_text(json.dumps({"label": label}), encoding="utf-8")
    lines = []
    for t in range(seconds):
        phase = "baseline" if t < EVENT_AT else "event" if t < EVENT_AT + 120 else "recovery"
        rebooted = reboot_at is not None and t >= reboot_at
        uptime = (t - reboot_at) * 1000 if rebooted else 900_000 + t * 1000
        state = "warmup" if rebooted else "ok"
        pm = 10 + (pm_rise if t >= EVENT_AT else 0)
        doc = air_doc(uptime, particulate={"pm2_5": pm, "pm1_0": pm // 2, "pm10": pm + 5, "state": state},
                      gas={"adc": 500 + (400 if t >= EVENT_AT else 0), "state": state},
                      co={"state": state})
        lines.append(json.dumps({"ts": 1_000_000.0 + t, "phase": phase, "doc": doc}))
    (path / "samples.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_windows_follow_the_hub_cadence_and_label_by_event(tmp_path):
    write_run(tmp_path / "run")
    rec = load_recording(tmp_path / "run")
    assert rec.resets == 0
    assert all(b.ts - a.ts == pytest.approx(15.0) for a, b in zip(rec.snapshots, rec.snapshots[1:]))
    windows = windows_for(rec, "aerosol")
    start = rec.snapshots[0].ts
    for w in windows:
        assert w.features.n_samples <= 41
        assert w.features.span_s >= recordings.MIN_SPAN_S
    labels = [w.label for w in windows]
    assert set(labels) == {"normal", "aerosol"}
    assert labels == sorted(labels, key=lambda label: label != "normal")  # normal windows come first
    first_event = next(i for i, w in enumerate(windows) if w.label == "aerosol")
    end = start + windows[first_event].features.span_s
    assert end >= rec.event_start + recordings.EVENT_LEAD_S


def test_reboot_mid_run_is_counted_and_warmup_dropped_unless_kept(tmp_path):
    write_run(tmp_path / "run", reboot_at=EVENT_AT + 5)
    dropped = load_recording(tmp_path / "run")
    kept = load_recording(tmp_path / "run", keep_warmup=True)
    assert dropped.resets == kept.resets == 1
    after = [s for s in dropped.snapshots if s.ts >= dropped.event_start + 10]
    assert after and all("gas" not in s.values for s in after)
    assert all("gas" in s.values for s in kept.snapshots)


def test_run_without_event_phase_is_skipped(tmp_path):
    (tmp_path / "run").mkdir()
    (tmp_path / "run" / "meta.json").write_text('{"label": "aerosol"}', encoding="utf-8")
    (tmp_path / "run" / "samples.jsonl").write_text(
        json.dumps({"ts": 1.0, "phase": "baseline", "doc": air_doc()}) + "\n", encoding="utf-8")
    assert load_recording(tmp_path / "run") is None


def test_single_tree_exports_as_a_one_tree_forest(tmp_path):
    write_run(tmp_path / "run")
    windows = windows_for(load_recording(tmp_path / "run"), "aerosol")
    feats = [w.features for w in windows]
    clf = build_model("tree", trees=1, max_depth=3, seed=0)
    clf.fit(to_matrix(feats), [w.label for w in windows])
    forest = forest_from_dict(export(clf, version="tree"))
    assert len(forest.trees) == 1
    for f, row in zip(feats, clf.predict_proba(to_matrix(feats))):
        assert probabilities(forest, f) == pytest.approx(list(row), abs=1e-5)


def test_main_maps_labels_skips_flat_and_unfinished_runs(tmp_path, capsys):
    write_run(tmp_path / "gas", label="natural_gas")
    write_run(tmp_path / "flat", label="cooking", pm_rise=0)
    write_run(tmp_path / "smoke", label="smoke")
    (tmp_path / "live").mkdir()  # recorder still running: no meta.json yet
    out = tmp_path / "model.json"
    recordings.main([str(tmp_path), "--synthetic-per-class", "5", "--trees", "3", "--out", str(out)])
    text = capsys.readouterr().out
    assert "skip live: no meta.json" in text
    assert "skip smoke: label 'smoke' is not a class" in text
    assert "flat:" in text and "FLAT" in text
    assert "gas:" in text and "'gas_leak'" in text
    forest = forest_from_dict(json.loads(out.read_text(encoding="utf-8")))
    assert "gas_leak" in forest.classes


def test_map_rejects_unknown_classes():
    with pytest.raises(SystemExit):
        recordings.parse_map(["smoke=bonfire"])
