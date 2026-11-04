import type { Incident } from "../api/types";

const LABELS = new Set(["smouldering_fire", "flaming_fire", "gas_leak", "steam", "cooking", "aerosol"]);
const CLOSED = new Set(["normal", "resolution", "false_alarm"]);

export function hasClassificationAlert(incident: Pick<Incident, "state" | "signature">): boolean {
  const signature = incident.signature;
  return !CLOSED.has(incident.state) && !!signature &&
    (LABELS.has(signature.label) || LABELS.has(signature.shadow_label ?? ""));
}
