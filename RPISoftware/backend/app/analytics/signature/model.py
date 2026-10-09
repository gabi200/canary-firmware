"""Shadow random-forest evaluator for the hazard signature classifier.

Walks a forest exported by tools/signature/train.py as JSON, in pure Python, so the
Pi needs no numpy or scikit-learn. Shadow mode only: callers store and log the
prediction, and no decision reads it. A missing, invalid or out-of-date model file
disables the shadow output and never raises.
"""

from __future__ import annotations

import json
import logging
import struct
from dataclasses import dataclass
from pathlib import Path

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures

log = logging.getLogger("canary.signature")

MODEL_PATH = Path(__file__).with_name("signature_model_v1.json")
_TREE_KEYS = ("feature", "threshold", "left", "right", "value", "missing_left")


@dataclass(frozen=True)
class ShadowPrediction:
    label: str
    confidence: float
    model_version: str


@dataclass(frozen=True)
class Forest:
    version: str
    classes: tuple[str, ...]
    trees: tuple[dict, ...]


def forest_from_dict(data: object) -> Forest:
    try:
        if list(data["feature_names"]) != list(FEATURE_NAMES):
            raise ValueError("feature_names do not match FEATURE_NAMES; retrain the model")
        version = str(data["version"])
        classes = tuple(str(c) for c in data["classes"])
        trees = tuple(data["trees"])
        for tree in trees:
            n = len(tree["left"])
            if n == 0 or any(len(tree[key]) != n for key in _TREE_KEYS):
                raise ValueError("tree arrays differ in length")
            for left, row in zip(tree["left"], tree["value"]):
                if left == -1 and len(row) != len(classes):
                    raise ValueError("leaf value width does not match classes")
    except (KeyError, TypeError) as exc:
        raise ValueError(f"malformed model: {exc!r}") from exc
    if not classes or not trees:
        raise ValueError("model has no classes or no trees")
    return Forest(version, classes, trees)


def load_forest(path: Path) -> Forest:
    with open(path, encoding="utf-8") as fh:
        return forest_from_dict(json.load(fh))


def _f32(x: float) -> float:
    """scikit-learn compares features as float32; match it so exported splits agree exactly."""
    try:
        return struct.unpack("f", struct.pack("f", x))[0]
    except OverflowError:
        return x


def probabilities(forest: Forest, features: SignatureFeatures) -> list[float]:
    x = features.as_vector()
    totals = [0.0] * len(forest.classes)
    for tree in forest.trees:
        left, right = tree["left"], tree["right"]
        node = 0
        for _ in range(len(left)):  # bounded: a malformed tree cannot loop forever
            if left[node] == -1:
                break
            value = x[tree["feature"][node]]
            go_left = tree["missing_left"][node] if value is None else _f32(value) <= tree["threshold"][node]
            node = left[node] if go_left else right[node]
        else:
            raise ValueError("tree deeper than its node count")
        for k, p in enumerate(tree["value"][node]):
            totals[k] += p
    return [t / len(forest.trees) for t in totals]


_cache: dict[Path, Forest | None] = {}


def predict(features: SignatureFeatures, path: Path = MODEL_PATH) -> ShadowPrediction | None:
    if path not in _cache:
        try:
            _cache[path] = load_forest(path)
        except (OSError, ValueError) as exc:
            log.warning("signature shadow model %s unavailable: %s", path, exc)
            _cache[path] = None
    forest = _cache[path]
    if forest is None:
        return None
    try:
        probs = probabilities(forest, features)
    except (IndexError, TypeError, ValueError) as exc:
        log.warning("signature shadow model %s failed: %s", path, exc)
        return None
    best = max(range(len(probs)), key=probs.__getitem__)
    return ShadowPrediction(forest.classes[best], probs[best], forest.version)
