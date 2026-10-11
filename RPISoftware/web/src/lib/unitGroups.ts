/**
 * Sensors grouped by apartment, in the scope bar's order (apartments in natural order, common
 * areas last), then by room (lib/scope). Used by the manager's environment and device health
 * cards. Sensors in a room the zone list does not know end up in one last "other" group.
 */
import { natural } from "./format";
import { prettyId } from "./labels";
import type { ScopeRoom, ScopeUnit } from "./scope";

export interface RoomGroup<N> {
  id: string;
  label: string;
  nodes: N[];
}

export interface UnitGroup<N> {
  /** unit id; OTHER_GROUP for the sensors of unknown rooms */
  id: string;
  label: string;
  common: boolean;
  rooms: RoomGroup<N>[];
  /** every sensor of the unit, room by room */
  nodes: N[];
}

export const OTHER_GROUP = "_other";

export function groupByUnit<N extends { zoneId: string; name: string }>(
  units: ScopeUnit[],
  rooms: ScopeRoom[],
  nodes: N[],
  otherLabel: string,
): UnitGroup<N>[] {
  const byZone = new Map<string, N[]>();
  for (const n of [...nodes].sort((a, b) => natural(a.name, b.name))) {
    byZone.set(n.zoneId, [...(byZone.get(n.zoneId) ?? []), n]);
  }
  const unitIds = new Set(units.map((u) => u.id));
  const placed = new Set(rooms.filter((r) => unitIds.has(r.unitId)).map((r) => r.id));

  const groups: UnitGroup<N>[] = units.map((u) => {
    const rs = rooms
      .filter((r) => r.unitId === u.id)
      .map((r) => ({ id: r.id, label: r.label, nodes: byZone.get(r.id) ?? [] }));
    return { id: u.id, label: u.label, common: u.common, rooms: rs, nodes: rs.flatMap((r) => r.nodes) };
  });

  const other = [...byZone].filter(([zoneId]) => !placed.has(zoneId));
  if (other.length) {
    const rs = other.map(([zoneId, ns]) => ({ id: zoneId, label: prettyId(zoneId), nodes: ns }));
    groups.push({ id: OTHER_GROUP, label: otherLabel, common: true, rooms: rs, nodes: rs.flatMap((r) => r.nodes) });
  }
  return groups;
}
