"""Synthetic training data, the sklearn export round trip, and the committed model."""

from __future__ import annotations

import pytest

from app.analytics.signature.features import FEATURE_NAMES, extract_features
from app.analytics.signature.model import MODEL_PATH, forest_from_dict, load_forest, predict, probabilities
from app.analytics.signature.rules import assess
from tests.signature_windows import scenario_snapshots
from tools.signature.synth import CLASSES, generate


def test_generate_is_deterministic_and_shaped():
    a, b = generate(seed=1, n_per_class=5), generate(seed=1, n_per_class=5)
    assert len(a) == len(CLASSES) * 5
    assert [label for label, _ in a] == [label for label, _ in b]
    assert all(len(snaps) == 40 for _, snaps in a)
    assert a[7][1][20] == b[7][1][20]


def test_rules_mostly_agree_with_synthetic_labels():
    windows = generate(seed=2, n_per_class=25)
    agree = sum(assess(extract_features(snaps)).label == label for label, snaps in windows)
    assert agree / len(windows) >= 0.7


def test_export_round_trips_sklearn_probabilities():
    pytest.importorskip("sklearn")
    from tools.signature.train import export, to_matrix, train_forest

    windows = generate(seed=3, n_per_class=30)
    feats = [extract_features(snaps) for _, snaps in windows]
    clf = train_forest(feats, [label for label, _ in windows], n_estimators=5, max_depth=5, seed=0)
    forest = forest_from_dict(export(clf, version="parity"))
    expected = clf.predict_proba(to_matrix(feats))
    for f, row in zip(feats, expected):
        assert probabilities(forest, f) == pytest.approx(list(row), abs=1e-5)


def test_committed_model_matches_features():
    forest = load_forest(MODEL_PATH)
    assert forest.version == "v1"
    assert set(forest.classes) == set(CLASSES)
    prediction = predict(extract_features(scenario_snapshots("steam")))
    assert prediction is not None and prediction.label in CLASSES
    assert len(FEATURE_NAMES) == 23
