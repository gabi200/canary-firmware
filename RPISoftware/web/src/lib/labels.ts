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
