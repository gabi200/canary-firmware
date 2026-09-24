import type { Zone } from "../api/types";

/** Prettify a raw machine id when no human label exists: "zone_kitchen" -> "Kitchen". */
export function prettyId(id?: string | null): string {
  if (!id) return "—";
  return id
    .replace(/^(zone|unit|flr|floor|bld|building|dev|device)_/i, "")
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

/** id -> human label map from the building's zones (seeded labels like "Bucătărie"). */
export function buildZoneNames(zones?: Zone[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const z of zones ?? []) m.set(z.id, z.label || prettyId(z.id));
  return m;
}

/** Friendly zone name, falling back to a prettified id, then an em dash. */
export function zoneLabel(names: Map<string, string>, id?: string | null): string {
  if (!id) return "—";
  return names.get(id) ?? prettyId(id);
}

const HAZARD_LABELS: Record<string, string> = {
  combustible_gas: "Gas leak",
  co: "Carbon monoxide",
  water_leak: "Water leak",
  particulate: "Smoke / particulates",
};

const SENSOR_LABELS: Record<string, string> = {
  combustible_gas: "Combustible gas",
  co: "Carbon monoxide",
  water_leak: "Water leak",
  particulate: "Smoke / particulates",
  wifi_presence: "Wi-Fi presence",
  radar_presence: "Radar presence",
};

/** Incident hazard_type -> label; unknown tokens degrade to spaced text. */
export function hazardLabel(type: string): string {
  return HAZARD_LABELS[type] ?? type.replace(/_/g, " ");
}

/** Device sensor_type -> label (presence types are occupancy, never hazards). */
export function sensorLabel(type: string): string {
  return SENSOR_LABELS[type] ?? type.replace(/_/g, " ");
}
