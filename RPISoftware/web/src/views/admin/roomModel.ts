import type { AdminFloor, AdminUnit, AdminZone } from "../../api/types";
import { natural } from "../../lib/format";
import { CARD_H, CARD_W, snap, type PlanRoom, type RoomStatus } from "./RoomPlan";

export { natural };

/** Room kinds the hub accepts (ZoneIn.kind), in menu order. */
export const ZONE_KINDS = ["kitchen", "living_room", "bedroom", "bathroom", "hallway", "stairwell", "boiler", "other"];

const RANK: Record<string, number> = { danger: 3, attention: 2, ok: 1 };

/** Worst status of the room's online sensors; `offline` when every sensor is offline. */
export function roomStatus(z: AdminZone): RoomStatus {
  if (z.nodes.length === 0) return "none";
  const online = z.nodes.filter((n) => n.online);
  if (online.length === 0) return "offline";
  let worst: RoomStatus = "ok";
  for (const n of online) if ((RANK[n.status] ?? 0) > (RANK[worst] ?? 0)) worst = n.status as RoomStatus;
  return worst;
}

export const hasPos = (z: AdminZone) => typeof z.pos_x === "number" && typeof z.pos_y === "number";

export function toPlanRoom(z: AdminZone, override?: { x: number; y: number }): PlanRoom {
  return {
    id: z.zone_id,
    label: z.label,
    kind: z.kind,
    x: override?.x ?? z.pos_x ?? 0,
    y: override?.y ?? z.pos_y ?? 0,
    status: roomStatus(z),
    nodes: z.nodes,
  };
}

/** First 0.5 m grid spot on a floor where a new room card would not overlap another one. */
export function freeSpot(rooms: { x: number; y: number }[]): { x: number; y: number } {
  const clear = (x: number, y: number) =>
    rooms.every((r) => Math.abs(r.x - x) >= CARD_W + 0.5 || Math.abs(r.y - y) >= CARD_H + 0.5);
  for (let y = 2; y <= 60; y += 2.5) {
    for (let x = 2; x <= 20; x += 3.5) {
      if (clear(x, y)) return { x: snap(x), y: snap(y) };
    }
  }
  return { x: 2, y: snap(Math.max(0, ...rooms.map((r) => r.y)) + 3) };
}

export function sortedFloors(floors: AdminFloor[] | undefined): AdminFloor[] {
  return [...(floors ?? [])].sort((a, b) => a.level - b.level || natural(a.label, b.label));
}

export function sortedUnits(units: AdminUnit[] | undefined): AdminUnit[] {
  // apartments before common areas, then by name ("Ap. 2" before "Ap. 10")
  return [...(units ?? [])].sort(
    (a, b) => Number(a.kind === "common") - Number(b.kind === "common") || natural(a.label, b.label),
  );
}

export function residentCount(u: AdminUnit): number {
  return Array.isArray(u.residents) ? u.residents.length : Number(u.residents ?? 0) || 0;
}

/** The usual rooms of a new apartment ("add the usual rooms"), in plan order. */
export const STANDARD_ROOMS = ["kitchen", "bathroom", "living_room", "bedroom"];

/** "Dormitor", then "Dormitor 2", "Dormitor 3" when the apartment already has those. */
export function uniqueName(base: string, taken: string[]): string {
  const used = new Set(taken.map((s) => s.trim().toLowerCase()));
  if (!used.has(base.toLowerCase())) return base;
  for (let i = 2; ; i++) if (!used.has(`${base} ${i}`.toLowerCase())) return `${base} ${i}`;
}

/** A free spot right next to the apartment's own rooms (right, below, left, above of each),
 *  else the first free spot of the floor: a new room lands where it belongs. */
export function spotNear(unitRooms: { x: number; y: number }[], floorRooms: { x: number; y: number }[]) {
  const clear = (x: number, y: number) =>
    floorRooms.every((r) => Math.abs(r.x - x) >= CARD_W + 0.5 || Math.abs(r.y - y) >= CARD_H + 0.5);
  // card + 0.5 m gap, rounded up to the 0.5 m grid (2.1 m would snap back to an overlap)
  const dx = Math.ceil((CARD_W + 0.5) * 2) / 2;
  const dy = Math.ceil((CARD_H + 0.5) * 2) / 2;
  for (const r of unitRooms) {
    for (const [x, y] of [[r.x + dx, r.y], [r.x, r.y + dy], [r.x - dx, r.y], [r.x, r.y - dy]]) {
      if (clear(x, y)) return { x: snap(x), y: snap(y) };
    }
  }
  return freeSpot(floorRooms);
}

/** Spots for a new apartment's usual rooms: the first free 2 x 2 block of the floor (same scan
 *  as freeSpot), else one after another next to each other. */
export function blockSpots(floorRooms: { x: number; y: number }[], n = STANDARD_ROOMS.length) {
  const clear = (x: number, y: number) =>
    floorRooms.every((r) => Math.abs(r.x - x) >= CARD_W + 0.5 || Math.abs(r.y - y) >= CARD_H + 0.5);
  for (let y = 2; y <= 60; y += 2.5) {
    for (let x = 2; x <= 20; x += 3.5) {
      const cells = Array.from({ length: n }, (_, i) => ({ x: x + (i % 2) * 3.5, y: y + Math.floor(i / 2) * 2.5 }));
      if (cells.every((c) => clear(c.x, c.y))) return cells.map((c) => ({ x: snap(c.x), y: snap(c.y) }));
    }
  }
  const out: { x: number; y: number }[] = [];
  for (let i = 0; i < n; i++) out.push(spotNear(out, [...floorRooms, ...out]));
  return out;
}
