import type { Zone } from "../api/types";
import { isMsgKey, type TFn } from "../i18n";

/** Prettify a raw machine id when no human label exists: "zone_kitchen" -> "Kitchen". */
export function prettyId(id?: string | null): string {
  if (!id) return "—";
  return id
    .replace(/^(zone|unit|flr|floor|bld|building|dev|device)_/i, "")
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

/** id -> human label map from the building's zones (seeded labels like "Bucătărie"). A label
 *  that several zones share gets its apartment: "Bucătărie · Ap. 12"; unique labels stay plain.
 *  Building data: shown verbatim, never translated. */
export function buildZoneNames(zones?: Zone[]): Map<string, string> {
  const label = (z: Zone) => z.label || prettyId(z.id);
  const key = (z: Zone) => label(z).trim().toLocaleLowerCase();
  const uses = new Map<string, number>();
  for (const z of zones ?? []) uses.set(key(z), (uses.get(key(z)) ?? 0) + 1);
  const m = new Map<string, string>();
  for (const z of zones ?? []) {
    m.set(z.id, (uses.get(key(z)) ?? 0) > 1 && z.unit_label ? `${label(z)} · ${z.unit_label}` : label(z));
  }
  return m;
}

/** Friendly zone name, falling back to a prettified id, then an em dash. */
export function zoneLabel(names: Map<string, string>, id?: string | null): string {
  if (!id) return "—";
  return names.get(id) ?? prettyId(id);
}

/** Translated label of a backend token (`<prefix>.<token>` in the dictionary); unknown
 *  tokens degrade to spaced text. */
export function tokenLabel(t: TFn, prefix: string, token: string): string {
  const key = `${prefix}.${token}`;
  return isMsgKey(key) ? t(key) : token.replace(/_/g, " ");
}

/** Incident hazard_type -> label. */
export const hazardLabel = (type: string, t: TFn) => tokenLabel(t, "hazard", type);

/** Device sensor_type -> label (presence types are occupancy, never hazards). */
export const sensorLabel = (type: string, t: TFn) => tokenLabel(t, "sensor", type);

/** Incident state (detection, evacuation, false_alarm, ...) -> label. */
export const stateLabel = (state: string, t: TFn) => tokenLabel(t, "state", state);

/** Analysis level (ok / attention / danger / unknown) -> label. */
export const levelLabel = (level: string, t: TFn) => tokenLabel(t, "level", level);

/** Node kind (air / water) -> label. */
export const kindLabel = (kind: string, t: TFn) => tokenLabel(t, "kind", kind);

/** Zone kind token (kitchen, hallway, ...) -> label; the zone's own name is never translated. */
export const zoneKindLabel = (kind: string, t: TFn) => tokenLabel(t, "zonekind", kind);

/** The zone kind as a note under its name, or "" when the name already says it
 *  ("Baie" / bathroom, "Hol scară" / hallway). */
export function zoneKindNote(label: string, kind: string, t: TFn): string {
  const plain = (v: string) => v.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
  const note = zoneKindLabel(kind, t);
  return plain(label).startsWith(plain(note)) ? "" : note;
}

/** Device-side state / enum value from a firmware status document -> label. */
export const deviceToken = (value: string, t: TFn) => tokenLabel(t, "dev", value);

/** Incident event reason token -> label (`held_<class>` / `held_signature_<label>` too). */
export function reasonLabel(reason: string, t: TFn): string {
  const sig = /^held_signature_(.+)$/.exec(reason);
  if (sig) return t("reason.heldSignature", { what: tokenLabel(t, "signature", sig[1]) });
  const held = /^held_(.+)$/.exec(reason);
  if (held) {
    // the likely_benign / transient signal labels already read "held · …"
    if (held[1] === "likely_benign" || held[1] === "transient") return tokenLabel(t, "signal", held[1]);
    return t("reason.held", { what: tokenLabel(t, "signal", held[1]) });
  }
  return tokenLabel(t, "reason", reason);
}

/** Event actor: "system" / "analytics" are translated, user ids are shown as-is. */
export function actorLabel(actor: string, t: TFn): string {
  const key = `actor.${actor}`;
  return isMsgKey(key) ? t(key) : actor;
}

/** Triangulation method ("concentration_weighted_centroid+time+airflow") -> label. */
export function triangulationMethodLabel(method: string, t: TFn): string {
  return method
    .split("+")
    .map((part) => tokenLabel(t, "tri", part))
    .join(" + ");
}
