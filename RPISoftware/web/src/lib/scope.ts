/**
 * Which part of the building the viewer looks at (floor, apartment, room), shared by the Sensors page
 * and every Administration tab. Remembered in this browser (best effort: storage may be blocked)
 * and synced between the components of the page. Default: the first apartment, not the whole
 * building; a stored apartment or room that no longer exists falls back to it.
 */
import { useMemo, useSyncExternalStore } from "react";

import { useAdminUnits } from "../api/adminHooks";
import { useZones } from "../api/hooks";
import type { Zone } from "../api/types";
import { useAuth } from "../auth/AuthContext";
import { useT } from "../i18n";
import { natural } from "./format";
import { prettyId } from "./labels";

/** "all" = the whole building (or floor) / every room of the apartment. */
export interface Scope {
  unit: string;
  room: string;
  /** a floor id or "all"; left out, it follows the chosen apartment (callers only pick units) */
  floor?: string;
}

export interface ScopeUnit {
  id: string;
  label: string;
  /** common areas (stairwell, boiler room): listed after the apartments */
  common: boolean;
  floorId: string;
  floorLabel: string;
}

export interface ScopeFloor {
  id: string;
  label: string;
}

export interface ScopeRoom {
  id: string;
  unitId: string;
  floorId: string;
  label: string;
  kind: string;
}

const STORAGE_KEY = "canary.scope";
const ALL: Scope = { unit: "all", room: "all", floor: "all" };
/** without the admin API (dispatchers), a unit holding only these rooms counts as common */
const SHARED_KINDS = new Set(["hallway", "stairwell", "boiler"]);

function load(): Scope | null {
  try {
    const v = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "null") as Partial<Scope> | null;
    if (typeof v?.unit === "string" && typeof v.room === "string")
      return { unit: v.unit, room: v.room, floor: typeof v.floor === "string" ? v.floor : undefined };
  } catch {
    /* storage unavailable (private mode, blocked) or garbage */
  }
  return null;
}

let stored: Scope | null = load();
const listeners = new Set<() => void>();

function subscribe(fn: () => void) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function setScope(next: Scope) {
  stored = next;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    /* not persisted; the choice still applies until the page reloads */
  }
  listeners.forEach((fn) => fn());
}

/** Units of the zone list; without the admin API a unit holding only shared rooms is common. */
export function unitsFromZones(zones: Zone[]): ScopeUnit[] {
  const byUnit = new Map<string, Zone[]>();
  for (const z of zones) byUnit.set(z.unit_id, [...(byUnit.get(z.unit_id) ?? []), z]);
  return [...byUnit].map(([id, zs]) => ({
    id,
    label: zs[0].unit_label || prettyId(id),
    common: zs.every((z) => SHARED_KINDS.has(z.kind)),
    floorId: zs[0].floor_id,
    floorLabel: zs[0].floor_label || prettyId(zs[0].floor_id),
  }));
}

export function useScope() {
  const { t } = useT();
  const { session } = useAuth();
  const zones = useZones();
  // the admin API also lists apartments without rooms, and knows which units are common
  const adminUnits = useAdminUnits(
    session?.role === "hoa_manager" || session?.role === "system_admin" || session?.role === "technician",
  );
  const raw = useSyncExternalStore(subscribe, () => stored, () => stored);

  const model = useMemo(() => {
    if (!zones.data) return { units: [] as ScopeUnit[], rooms: [] as ScopeRoom[], floors: [] as ScopeFloor[] };
    const units = (
      adminUnits.data
        ? adminUnits.data.map((u) => ({
            id: u.unit_id,
            label: u.label,
            common: u.kind === "common",
            floorId: u.floor_id,
            floorLabel: u.floor_label || prettyId(u.floor_id),
          }))
        : unitsFromZones(zones.data)
    ).sort((a, b) => Number(a.common) - Number(b.common) || natural(a.label, b.label));
    const rank = new Map(units.map((u, i) => [u.id, i]));
    const rooms = zones.data
      .map((z) => ({ id: z.id, unitId: z.unit_id, floorId: z.floor_id, label: z.label || prettyId(z.id), kind: z.kind }))
      .sort((a, b) => (rank.get(a.unitId) ?? units.length) - (rank.get(b.unitId) ?? units.length) || natural(a.label, b.label));
    const floors = [...new Map(units.map((u) => [u.floorId, { id: u.floorId, label: u.floorLabel }])).values()].sort(
      (a, b) => natural(a.label, b.label),
    );
    return { units, rooms, floors };
  }, [zones.data, adminUnits.data]);

  return useMemo(() => {
    const { units, rooms, floors } = model;
    const firstHome = units.find((u) => !u.common);
    const fallback: Scope = { unit: firstHome?.id ?? "all", room: "all", floor: firstHome?.floorId ?? "all" };
    let scope = fallback;
    if (raw?.unit === "all") {
      scope = { ...ALL, floor: floors.some((f) => f.id === raw.floor) ? raw.floor : "all" };
    } else if (raw && units.some((u) => u.id === raw.unit)) {
      const floorId = units.find((u) => u.id === raw.unit)!.floorId; // an apartment implies its floor
      scope = {
        unit: raw.unit,
        room: rooms.some((r) => r.id === raw.room && r.unitId === raw.unit) ? raw.room : "all",
        floor: floorId,
      };
    }
    const unit = units.find((u) => u.id === scope.unit) ?? null;
    const room = rooms.find((r) => r.id === scope.room) ?? null;
    const floor = floors.find((f) => f.id === scope.floor) ?? null;
    const unitOf = new Map(rooms.map((r) => [r.id, r.unitId]));
    const floorOf = new Map(rooms.map((r) => [r.id, r.floorId]));
    return {
      scope,
      setScope,
      /** apartments, then common areas */
      units,
      /** every room, grouped by unit (units' order), by name inside */
      rooms,
      /** floors that have apartments or common areas, by name ("Etaj 2" before "Etaj 10") */
      floors,
      unit,
      room,
      floor,
      /** "Ap. 12 · Bucătărie", "Ap. 12", "Etaj 3" or "Whole building" */
      title: unit ? (room ? `${unit.label} · ${room.label}` : unit.label) : floor ? floor.label : t("scope.building"),
      /** the room list is known (or failed: then the whole building is shown) */
      ready: !!zones.data || zones.isError,
      /** a zone is inside the scope; zones the hub does not list only under the whole building */
      includes: (zoneId: string) =>
        scope.unit === "all"
          ? !floor || floorOf.get(zoneId) === floor.id
          : scope.room !== "all"
            ? zoneId === scope.room
            : unitOf.get(zoneId) === scope.unit,
    };
  }, [model, raw, zones.data, zones.isError, t]);
}
