"""Train the shadow signature model on synthetic windows and export it as JSON.

Run from RPISoftware/backend with the train extra installed:
    pip install -e ".[train]"
    python -m tools.signature.train
It overwrites app/analytics/signature/signature_model_v1.json; commit the result.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, confusion_matrix
from sklearn.model_selection import train_test_split

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures, extract_features
from app.analytics.signature.model import MODEL_PATH
from app.analytics.signature.rules import assess
from tools.signature.synth import CLASSES, generate

MODEL_VERSION = "v1"
# Every feature is >= 0, so -1 marks "missing"; export() routes missing values the same way.
MISSING = -1.0
VALUE_DECIMALS = 6


def to_matrix(rows: list[SignatureFeatures]) -> np.ndarray:
    return np.array([[MISSING if v is None else v for v in f.as_vector()] for f in rows], dtype=np.float64)


def train_forest(features: list[SignatureFeatures], labels: list[str], *, n_estimators: int = 40,
                 max_depth: int = 6, seed: int = 0) -> RandomForestClassifier:
    clf = RandomForestClassifier(n_estimators=n_estimators, max_depth=max_depth, random_state=seed)
    clf.fit(to_matrix(features), np.array(labels))
    return clf


def export(clf: RandomForestClassifier, version: str = MODEL_VERSION) -> dict:
    trees = []
    for estimator in clf.estimators_:
        t = estimator.tree_
        values = []
        for left, row in zip(t.children_left, t.value[:, 0, :]):
            total = float(row.sum())
            leaf = [round(float(v) / total, VALUE_DECIMALS) if total else 0.0 for v in row]
            values.append(leaf if left == -1 else [])
        trees.append({
            "feature": [int(i) for i in t.feature],
            "threshold": [float(x) for x in t.threshold],
            "left": [int(i) for i in t.children_left],
            "right": [int(i) for i in t.children_right],
            "value": values,
            "missing_left": [bool(MISSING <= x) for x in t.threshold],
        })
    return {"version": version, "feature_names": list(FEATURE_NAMES), "classes": [str(c) for c in clf.classes_],
            "trees": trees}


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Train the shadow signature model on synthetic windows.")
    parser.add_argument("--per-class", type=int, default=400)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", type=Path, default=MODEL_PATH)
    args = parser.parse_args(argv)

    windows = generate(seed=args.seed, n_per_class=args.per_class)
    labels = [label for label, _ in windows]
    features = [extract_features(snaps) for _, snaps in windows]
    f_train, f_test, y_train, y_test = train_test_split(
        features, labels, test_size=0.25, random_state=args.seed, stratify=labels)
    clf = train_forest(f_train, y_train, seed=args.seed)

    predicted = list(clf.predict(to_matrix(f_test)))
    rules = [assess(f).label for f in f_test]
    print(f"model vs synthetic truth: {accuracy_score(y_test, predicted):.3f}")
    print(f"rules vs synthetic truth: {accuracy_score(y_test, rules):.3f}")
    print(f"model vs rules:           {accuracy_score(rules, predicted):.3f}")
    print("confusion matrix (rows = truth, columns = model, same order):")
    for name, row in zip(CLASSES, confusion_matrix(y_test, predicted, labels=list(CLASSES))):
        print(f"{name:>17} " + " ".join(f"{n:4d}" for n in row))

    args.out.write_text(json.dumps(export(clf), separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
