import assert from "node:assert/strict";
import test from "node:test";
import { hasClassificationAlert } from "../src/lib/classification.ts";

const incident = (label, shadow_label = null, state = "verification") => ({ state, signature: { label, shadow_label } });

test("shows rule classifications including benign aerosol events", () => {
  for (const label of ["smouldering_fire", "flaming_fire", "gas_leak", "steam", "cooking", "aerosol"]) {
    assert.equal(hasClassificationAlert(incident(label)), true);
  }
});

test("shows a model-only prediction and disagreement between layers", () => {
  assert.equal(hasClassificationAlert(incident("unknown", "gas_leak")), true);
  assert.equal(hasClassificationAlert(incident("aerosol", "flaming_fire")), true);
});

test("hides missing, unknown and normal classifications", () => {
  assert.equal(hasClassificationAlert({ state: "alarm", signature: null }), false);
  assert.equal(hasClassificationAlert(incident("normal", "unknown")), false);
  assert.equal(hasClassificationAlert(incident("unknown", "normal")), false);
  assert.equal(hasClassificationAlert(incident("unsupported_label")), false);
});

test("closed incidents never leave a classification alert behind", () => {
  for (const state of ["resolution", "false_alarm", "normal"]) {
    assert.equal(hasClassificationAlert(incident("gas_leak", "aerosol", state)), false);
  }
});
