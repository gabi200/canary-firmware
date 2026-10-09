"""Shadow forest evaluator: traversal, missing values, averaging, and failure handling."""

from __future__ import annotations

import json

import pytest

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures
from app.analytics.signature.model import forest_from_dict, predict, probabilities

PM = FEATURE_NAMES.index("rise_pm2_5")
RH = FEATURE_NAMES.index("rh_delta")


def features(**values) -> SignatureFeatures:
    base = dict.fromkeys(FEATURE_NAMES)
    base.update(n_samples=40.0, span_s=585.0)
    base.update(values)
    return SignatureFeatures(**base)


def tiny_model() -> dict:
    def split(feature: int, threshold: float, left_leaf: list[float], right_leaf: list[float]) -> dict:
        return {"feature": [feature, -2, -2], "threshold": [threshold, -2.0, -2.0], "left": [1, -1, -1],
                "right": [2, -1, -1], "value": [[], left_leaf, right_leaf], "missing_left": [True, False, False]}
    return {"version": "test", "feature_names": list(FEATURE_NAMES), "classes": ["normal", "steam"],
            "trees": [split(PM, 0.5, [1.0, 0.0], [0.0, 1.0]), split(RH, 10.0, [1.0, 0.0], [0.2, 0.8])]}


def test_probabilities_average_the_trees():
    forest = forest_from_dict(tiny_model())
    assert probabilities(forest, features(rise_pm2_5=1.0, rh_delta=20.0)) == pytest.approx([0.1, 0.9])


def test_threshold_is_inclusive_on_the_left():
    forest = forest_from_dict(tiny_model())
    assert probabilities(forest, features(rise_pm2_5=0.5, rh_delta=10.0)) == pytest.approx([1.0, 0.0])


def test_missing_values_follow_missing_left():
    forest = forest_from_dict(tiny_model())
    assert probabilities(forest, features()) == pytest.approx([1.0, 0.0])


def test_predict_returns_the_best_class(tmp_path):
    path = tmp_path / "model.json"
    path.write_text(json.dumps(tiny_model()))
    p = predict(features(rise_pm2_5=1.0, rh_delta=20.0), path)
    assert (p.label, p.confidence, p.model_version) == ("steam", pytest.approx(0.9), "test")


@pytest.mark.parametrize("mutate", [
    lambda m: m.update(feature_names=list(FEATURE_NAMES)[:-1]),
    lambda m: m.update(classes=[]),
    lambda m: m["trees"][0].update(left=[1, -1]),
    lambda m: m["trees"][0]["value"].__setitem__(1, [1.0]),
    lambda m: m.pop("trees"),
])
def test_malformed_models_are_rejected(mutate):
    model = tiny_model()
    mutate(model)
    with pytest.raises(ValueError):
        forest_from_dict(model)


def test_predict_is_none_for_missing_or_broken_files(tmp_path):
    assert predict(features(), tmp_path / "absent.json") is None
    broken = tmp_path / "broken.json"
    broken.write_text("{not json")
    assert predict(features(), broken) is None
    stale = tmp_path / "stale.json"
    model = tiny_model()
    model["feature_names"] = ["old_feature"]
    stale.write_text(json.dumps(model))
    assert predict(features(), stale) is None


def test_predict_is_none_when_a_tree_points_outside_its_arrays(tmp_path):
    model = tiny_model()
    model["trees"][0]["left"] = [7, -1, -1]
    path = tmp_path / "bad_index.json"
    path.write_text(json.dumps(model))
    assert predict(features(rise_pm2_5=0.1), path) is None
