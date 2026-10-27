/**
 * Model behind the interactive hazard map: an apartment-first schematic of the building (floor ->
 * apartment block -> room tiles), live (or replayed) hazard state per zone and sensor, and the
 * triangulation overlay.
 *
 * The schematic is NOT to scale: rooms are tiles in a tidy grid inside their apartment's block,
 * ordered by their building position (rows by y, each row by x) so a flat still resembles its
 * real arrangement. The plan is laid out for the measured width of its card and drawn 1:1, so the
 * SVG units below are CSS pixels.
 *
 * Room tile geometry: a reserved HEADER row (name, status, reading, chips), a BODY band for map
 * overlays (source marker, contributor dots; only reserved while an incident is open) and a
 * FOOTER row with the room's sensor chips. Overlays are clamped into the body band and drawn
 * under the text layer, so they never cover text.
 */
import type { Device, Incident, MotionState, NodeHistory, NodeOut, Reading, Triangulation, Zone } from "../api/types";
import type { TFn } from "../i18n";
import { natural } from "./format";
import { levelLabel, prettyId } from "./labels";
import { METRICS, toRows, type Level, type Metric, type Row, channelTrust, keyOf } from "./metrics";
import { pickNum } from "./nodes";
import { parseTs } from "./time";

interface Geometry {
  pad: number;
  /** floor label row (0: no floor labels) */
  floorHead: number;
  floorGap: number;
  blockGap: number;
  blockPad: number;
  /** apartment header row inside its block */
  blockHead: number;
  tileGapX: number;
  /** room for the "estimated source" badge that straddles a tile's top edge */
  tileGapY: number;
  minTile: number;
  maxTile: number;
  tileHead: number;
  tileBody: number;
  tileFoot: number;
}

/** Dashboard plan: every text >= 12 px at 1:1. */
const FULL: Geometry = {
  pad: 12,
  floorHead: 30,
  floorGap: 18,
  blockGap: 14,
  blockPad: 12,
  blockHead: 46,
  tileGapX: 10,
  tileGapY: 14,
  minTile: 164,
  maxTile: 300,
  tileHead: 50,
  tileBody: 54,
  tileFoot: 32,
};

/** Mini-map of the command view (scaled down): rooms are icon tiles, no body / footer rows. */
const COMPACT: Geometry = {
  pad: 8,
  floorHead: 0,
  floorGap: 10,
  blockGap: 10,
  blockPad: 6,
  blockHead: 34,
  tileGapX: 6,
  tileGapY: 6,
  minTile: 70,
  maxTile: 120,
  tileHead: 44,
  tileBody: 0,
  tileFoot: 0,
};

export const HEADER_H = FULL.tileHead;
export const FOOTER_H = FULL.tileFoot;
/** Width the mini-map is laid out for (it is drawn scaled into the command view's header). */
export const MINI_WIDTH = 600;

export interface Placed {
  zone: Zone;
  /** top-left corner and size of the room tile */
  x: number;
  y: number;
  w: number;
  h: number;
  cx: number;
  cy: number;
  /** vertical overlay band inside the tile (the whole tile when the layout reserves none) */
  body: { y0: number; y1: number };
}

/** An apartment (or common areas) block holding its room tiles. */
export interface UnitBlock {
  id: string;
  label: string;
  common: boolean;
  floorId: string;
  x: number;
  y: number;
  w: number;
  h: number;
  /** its rooms, in tile order */
  zoneIds: string[];
}

export interface FloorHead {
  id: string;
  /** the backend's label ("Etaj 3"); null when it sends none */
  label: string | null;
  x: number;
  y: number;
  w: number;
}

export interface Layout {
  width: number;
  height: number;
  /** room tiles in reading order (floor, apartment, tile order) */
  zones: Placed[];
  units: UnitBlock[];
  /** floor label rows (none in the compact layout) */
  floors: FloorHead[];
  compact: boolean;
  /** building metres -> SVG units: always null, the schematic is not to scale */
  toSvg: ((bx: number, by: number) => { x: number; y: number }) | null;
  /** SVG units per metre: always null (see toSvg) */
  scale: number | null;
}

export interface UnitInfo {
  label: string;
  /** common areas (stairwell, boiler room): drawn as a band after the apartments */
  common: boolean;
}

export interface LayoutOptions {
  /** width to lay the plan out for (CSS px; it is drawn 1:1) */
  width: number;
  /** label and kind per unit id (lib/scope); otherwise the zones' unit label, residential */
  units?: Map<string, UnitInfo>;
  /** reserve the overlay band in every tile (an incident is open) */
  overlays?: boolean;
  /** small schematic for the command view's mini-map */
  compact?: boolean;
}

const posX = (z: Zone) => (typeof z.pos_x === "number" ? z.pos_x : Infinity);
const posY = (z: Zone) => (typeof z.pos_y === "number" ? z.pos_y : Infinity);
const byLabel = (a: Zone, b: Zone) => natural(a.label || a.id, b.label || b.id);

/** Tile order for a grid of `cols` columns: rows by building y, each row by x (rooms without a
 *  position last, by name), so the grid keeps the flat's real arrangement. */
function arrange(zones: Zone[], cols: number): Zone[] {
  const rows = [...zones].sort((a, b) => posY(a) - posY(b) || posX(a) - posX(b) || byLabel(a, b));
  const out: Zone[] = [];
  for (let i = 0; i < rows.length; i += cols) {
    out.push(...rows.slice(i, i + cols).sort((a, b) => posX(a) - posX(b) || posY(a) - posY(b) || byLabel(a, b)));
  }
  return out;
}

/**
 * Apartment-first schematic: per floor (natural order) a row-wrapped grid of apartment blocks
 * (natural order: "Ap. 2" < "Ap. 12"), then each common unit as a full-width band, like a
 * corridor. Block columns are the most that keep room tiles at least `minTile` wide; a lone
 * column of blocks puts a whole flat in one row of tiles when it fits (shorter plan), a phone
 * stacks the tiles. Rows of blocks share one height so the grid stays tidy.
 */
export function layoutZones(zones: Zone[], opts: LayoutOptions): Layout {
  const g = opts.compact ? COMPACT : FULL;
  const width = Math.max(Math.round(opts.width), 2 * g.pad + g.minTile + 2 * g.blockPad);
  const inner = width - 2 * g.pad;

  // floor -> unit -> rooms
  const floors = new Map<string, Map<string, Zone[]>>();
  for (const z of zones) {
    const units = floors.get(z.floor_id) ?? new Map<string, Zone[]>();
    units.set(z.unit_id, [...(units.get(z.unit_id) ?? []), z]);
    floors.set(z.floor_id, units);
  }
  const floorLabel = (id: string) => [...(floors.get(id)?.values() ?? [])][0]?.[0]?.floor_label || null;
  const plan = [...floors.keys()]
    .sort((a, b) => natural(floorLabel(a) ?? a, floorLabel(b) ?? b))
    .map((floorId) => {
      const units = [...floors.get(floorId)!].map(([id, zs]) => {
        const info = opts.units?.get(id);
        return { id, zones: zs, label: info?.label || zs[0].unit_label || prettyId(id), common: info?.common ?? false };
      });
      const sort = (a: { label: string }, b: { label: string }) => natural(a.label, b.label);
      return {
        id: floorId,
        homes: units.filter((u) => !u.common).sort(sort),
        commons: units.filter((u) => u.common).sort(sort),
      };
    });

  const maxHomes = Math.max(1, ...plan.map((f) => f.homes.length));
  const maxRooms = Math.max(1, ...plan.flatMap((f) => f.homes.map((u) => u.zones.length)));
  const blockFor = (tcols: number, tile: number) => tcols * tile + (tcols - 1) * g.tileGapX + 2 * g.blockPad;
  const cols = Math.min(maxHomes, Math.max(1, Math.floor((inner + g.blockGap) / (blockFor(2, g.minTile) + g.blockGap))));
  const span = (inner - (cols - 1) * g.blockGap) / cols;
  let tcols = 2;
  if (span < blockFor(2, g.minTile)) tcols = 1;
  else if (cols === 1 && maxRooms >= 3 && span >= blockFor(4, g.minTile)) tcols = 4;
  const tileW = Math.min(g.maxTile, (span - 2 * g.blockPad - (tcols - 1) * g.tileGapX) / tcols);
  const blockW = blockFor(tcols, tileW);
  const bandW = cols * blockW + (cols - 1) * g.blockGap;
  const tileH = g.tileHead + (opts.overlays ? g.tileBody : 0) + g.tileFoot;
  const heightFor = (n: number, c: number) => {
    const rows = Math.max(1, Math.ceil(n / c));
    return g.blockHead + rows * tileH + (rows - 1) * g.tileGapY + g.blockPad;
  };

  const placed: Placed[] = [];
  const blocks: UnitBlock[] = [];
  const heads: FloorHead[] = [];
  const place = (
    unit: { id: string; label: string; common: boolean; zones: Zone[] },
    floorId: string,
    box: { x: number; y: number; w: number; h: number },
    c: number,
    tw: number,
  ) => {
    const { x, y, w, h } = box;
    const order = arrange(unit.zones, c);
    order.forEach((zone, k) => {
      const tx = x + g.blockPad + (k % c) * (tw + g.tileGapX);
      const ty = y + g.blockHead + Math.floor(k / c) * (tileH + g.tileGapY);
      const body = opts.overlays
        ? { y0: ty + g.tileHead + 2, y1: ty + g.tileHead + g.tileBody - 2 }
        : { y0: ty + 4, y1: ty + tileH - 4 };
      placed.push({ zone, x: tx, y: ty, w: tw, h: tileH, cx: tx + tw / 2, cy: ty + tileH / 2, body });
    });
    blocks.push({ id: unit.id, label: unit.label, common: unit.common, floorId, x, y, w, h, zoneIds: order.map((z) => z.id) });
  };

  let y = g.pad;
  plan.forEach((floor, fi) => {
    if (fi > 0) y += g.floorGap;
    if (g.floorHead) {
      heads.push({ id: floor.id, label: floorLabel(floor.id), x: g.pad, y, w: bandW });
      y += g.floorHead;
    }
    for (let i = 0; i < floor.homes.length; i += cols) {
      const row = floor.homes.slice(i, i + cols);
      const h = Math.max(...row.map((u) => heightFor(u.zones.length, tcols)));
      row.forEach((u, j) => place(u, floor.id, { x: g.pad + j * (blockW + g.blockGap), y, w: blockW, h }, tcols, tileW));
      y += h + g.blockGap;
    }
    for (const u of floor.commons) {
      // a band is wide: its few rooms may take wider tiles (long names like "Centrală termică")
      const bandInner = bandW - 2 * g.blockPad;
      const n = Math.max(1, u.zones.length);
      const tw = Math.min(bandInner, Math.max(tileW, Math.min(g.maxTile, (bandInner - (n - 1) * g.tileGapX) / n)));
      const ccols = Math.max(1, Math.floor((bandInner + g.tileGapX) / (tw + g.tileGapX)));
      const h = heightFor(u.zones.length, ccols);
      place(u, floor.id, { x: g.pad, y, w: bandW, h }, ccols, tw);
      y += h + g.blockGap;
    }
    y -= g.blockGap;
  });

  return {
    width,
    height: Math.max(y + g.pad, 2 * g.pad + tileH),
    zones: placed,
    units: blocks,
    floors: heads,
    compact: !!opts.compact,
    toSvg: null,
    scale: null,
  };
}

/** Overlay band of a room tile (where the source marker and contributor dots may go). */
export function bodyBand(p: Placed) {
  return { x0: p.x + 14, x1: p.x + p.w - 14, y0: p.body.y0, y1: p.body.y1 };
}

// --------------------------------------------------------------------------- //
// Sensors and their hazard state
// --------------------------------------------------------------------------- //

/** Hazard channels per node kind (presence is occupancy, never a hazard). */
export const HAZARD_METRICS: Record<string, Metric[]> = {
  air: [METRICS.co, METRICS.gas, METRICS.pm25, METRICS.pm10],
  water: [METRICS.probe],
};

/** History fields used by the map replay and the drawer (same keys -> shared cache). */
export const MAP_FIELDS: Record<string, string[]> = {
  air: HAZARD_METRICS.air.map((m) => m.field),
  water: HAZARD_METRICS.water.map((m) => m.field),
};

/** Node channel (device id suffix) -> metric of its canonical reading. */
const CHANNEL_METRIC: Record<string, Metric> = {
  co: METRICS.co,
  gas: METRICS.gas,
  particulate: METRICS.pm25,
  leak: METRICS.probe,
};

const PRESENCE_TYPES = new Set(["wifi_presence", "radar_presence"]);
const RANK: Record<Level, number> = { danger: 3, attention: 2, ok: 1, none: 0, unknown: 0 };
export const worse = (a: Level, b: Level): Level => (RANK[b] > RANK[a] ? b : a);

export interface ChannelState {
  metric: Metric;
  value: number | null;
  trust: ReturnType<typeof channelTrust>;
  level: Level;
  warn: number | null;
  danger: number | null;
  /** value / danger threshold, clamped to 0..1 (null without a threshold or value) */
  ratio: number | null;
}

export interface MapSensor {
  id: string;
  type: "air" | "water" | "device";
  name: string;
  zoneId: string;
  online: boolean;
  lastTs: string | null;
  level: Level;
  ratio: number | null;
  /** hardware nodes: one entry per hazard channel */
  channels: ChannelState[];
  node?: NodeOut;
  /** simulated / legacy devices (no device thresholds): latest canonical reading */
  device?: Device;
  reading?: Reading;
  /** presence-only devices never colour a zone */
  hazard: boolean;
}

const clamp01 = (v: number) => Math.max(0, Math.min(1, v));

function channelState(m: Metric, doc: unknown, value: number | null, trust: ChannelState["trust"]): ChannelState {
  const warn = m.refs ? pickNum(doc, m.refs[0].path) : null;
  const danger = m.refs ? pickNum(doc, m.refs[1].path) : null;
  const level: Level = value == null ? "unknown" : m.level(value, doc);
  return { metric: m, value, trust, level, warn, danger, ratio: value != null && danger ? clamp01(value / danger) : null };
}

function summarize(s: Omit<MapSensor, "level" | "ratio">): MapSensor {
  let level: Level = "unknown";
  let ratio: number | null = null;
  for (const c of s.channels) {
    level = level === "unknown" ? c.level : worse(level, c.level);
    if (c.ratio != null) ratio = Math.max(ratio ?? 0, c.ratio);
  }
  return { ...s, level, ratio };
}

function nodeSensor(node: NodeOut): MapSensor {
  const doc = node.status;
  const channels = (HAZARD_METRICS[node.kind] ?? []).map((m) => {
    const trust = channelTrust(doc, m.channel);
    return channelState(m, doc, trust === "ok" ? pickNum(doc, m.field) : null, trust);
  });
  return summarize({
    id: node.id,
    type: node.kind === "water" ? "water" : "air",
    name: node.name || node.id,
    zoneId: node.zone_id,
    online: node.online && !node.analysis?.stale,
    lastTs: node.last_seen_ts,
    channels,
    node,
    hazard: true,
  });
}

const EDGE_LEVEL: Record<string, Level> = { alarm: "danger", warn: "attention", normal: "ok" };

function deviceSensor(device: Device, reading: Reading | undefined): MapSensor {
  const hazard = !PRESENCE_TYPES.has(device.sensor_type);
  return {
    id: device.id,
    type: "device",
    name: device.id,
    zoneId: device.zone_id,
    online: device.status === "ok",
    lastTs: reading?.ts ?? device.last_seen_ts,
    channels: [],
    device,
    reading,
    hazard,
    level: !hazard ? "none" : reading ? (EDGE_LEVEL[reading.edge_state] ?? "unknown") : "unknown",
    ratio: null,
  };
}

/** Every sensor of the building: hardware nodes (thresholds from their own status document) and
 *  the other devices (simulated / legacy, graded by their edge state only). */
export function liveSensors(nodes: NodeOut[], devices: Device[], latest: Map<string, Reading>): MapSensor[] {
  const nodeIds = new Set(nodes.map((n) => n.id));
  // ponytail: a legacy device shows only while it has a recent reading (the seeded demo devices
  // never report, and grey "no data" chips next to real nodes made the plan unreadable)
  const others = devices.filter((d) => !nodeIds.has(d.id.split(":")[0]) && latest.has(d.id));
  return [...nodes.map(nodeSensor), ...others.map((d) => deviceSensor(d, latest.get(d.id)))];
}

export interface History {
  rows: Row[];
}

/** Last row at or before `t` (rows ascending; null past a gap row). */
function rowAt(rows: Row[], t: number): Row | null {
  let lo = 0;
  let hi = rows.length - 1;
  let best = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if ((rows[mid].t ?? 0) <= t) {
      best = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return best < 0 ? null : rows[best];
}

/** The sensors as they were at time `t`, from node history (thresholds from the current
 *  document). Sensors without history at `t` (other devices, nodes not fetched) are unknown. */
export function sensorsAt(sensors: MapSensor[], histories: Map<string, Row[]>, t: number): MapSensor[] {
  return sensors.map((s) => {
    if (!s.hazard) return s;
    const rows = histories.get(s.id);
    if (!s.node || !rows) return { ...s, level: "unknown", ratio: null, channels: s.channels.map((c) => ({ ...c, value: null, level: "unknown", ratio: null })) };
    const row = rowAt(rows, t);
    const doc = s.node.status;
    const channels = s.channels.map((c) => {
      const v = row?.[keyOf(c.metric.field)] ?? null;
      return channelState(c.metric, doc, v, v == null ? "missing" : "ok");
    });
    return summarize({ ...s, channels, lastTs: row ? new Date(row.t as number).toISOString() : null });
  });
}

/** Node history rows (gaps as nulls) per node id. */
export function historyRows(nodes: NodeOut[], data: (NodeHistory | undefined)[]): Map<string, Row[]> {
  const out = new Map<string, Row[]>();
  for (const h of data) {
    if (!h) continue;
    const node = nodes.find((n) => n.id === h.node_id);
    if (!node) continue;
    out.set(h.node_id, toRows(h.points ?? [], MAP_FIELDS[node.kind] ?? [], node.kind));
  }
  return out;
}

// --------------------------------------------------------------------------- //
// Zones
// --------------------------------------------------------------------------- //

export interface ZoneView {
  placed: Placed;
  level: Level;
  ratio: number | null;
  sensors: MapSensor[];
  isSource: boolean;
  isAffected: boolean;
  occupancy: number;
  priority: number;
  /** ESPectre Wi-Fi motion, live only (staff); undefined: none shown */
  motion?: MotionState;
}

/** The zone's own status, honest during an open incident: a source / affected zone whose
 *  readings are normal again says so instead of a lone "OK" (isSource / isAffected are only
 *  set while an incident is open). */
export function zoneStatusText(z: ZoneView, t: TFn): string {
  if (z.level === "unknown") return t("map.noData");
  if ((z.isSource || z.isAffected) && z.level === "ok") return t("cmd.readingsNormal");
  return levelLabel(z.level, t);
}

export function zoneViews(
  layout: Layout,
  sensors: MapSensor[],
  opts: {
    incident: Incident | null;
    sourceZoneId: string | null;
    occupancyByZone: Record<string, number>;
    priorityByUnit: Record<string, number>;
  },
): ZoneView[] {
  const affected = new Set(opts.incident?.affected_zone_ids ?? []);
  if (opts.incident?.primary_zone_id) affected.add(opts.incident.primary_zone_id);
  return layout.zones.map((placed) => {
    const zs = sensors.filter((s) => s.zoneId === placed.zone.id);
    let level: Level = "unknown";
    let ratio: number | null = null;
    for (const s of zs) {
      if (!s.hazard) continue;
      level = level === "unknown" ? s.level : worse(level, s.level);
      if (s.ratio != null) ratio = Math.max(ratio ?? 0, s.ratio);
    }
    return {
      placed,
      level,
      ratio,
      sensors: zs,
      isSource: opts.sourceZoneId === placed.zone.id,
      isAffected: !!opts.incident && affected.has(placed.zone.id),
      occupancy: opts.occupancyByZone[placed.zone.id] ?? 0,
      priority: opts.priorityByUnit[placed.zone.unit_id] ?? 0,
    };
  });
}

// --------------------------------------------------------------------------- //
// Triangulation overlay
// --------------------------------------------------------------------------- //

export interface ContributorView {
  deviceId: string;
  /** sensor (node or device) the drawer scrolls to */
  sensorId: string;
  name: string;
  zoneId: string;
  value: number;
  unit: string;
  digits: number;
  weight: number;
  x: number;
  y: number;
}

export interface SourceView {
  x: number;
  y: number;
  /** uncertainty halo radius (SVG units) */
  r: number;
  confidence: number;
  zoneId: string | null;
  airflow: boolean;
}

const UNIT_TEXT: Record<string, string> = { "ug/m3": "µg/m³", adc: "ADC" };

export function contributorViews(
  tri: Triangulation | undefined,
  layout: Layout,
  nodes: NodeOut[],
  latest: Map<string, Reading>,
): ContributorView[] {
  if (!tri) return [];
  const byZone = new Map<string, Triangulation["contributors"]>();
  for (const c of tri.contributors ?? []) byZone.set(c.zone_id, [...(byZone.get(c.zone_id) ?? []), c]);
  const out: ContributorView[] = [];
  for (const [zoneId, list] of byZone) {
    const placed = layout.zones.find((p) => p.zone.id === zoneId);
    if (!placed) continue;
    const band = bodyBand(placed);
    // one slot per contributor across the band (value labels are ~56 units wide)
    const step = Math.min(96, (band.x1 - band.x0) / Math.max(list.length, 1));
    list.forEach((c, i) => {
      const [nodeId, channel] = c.device_id.split(":");
      const node = channel ? nodes.find((n) => n.id === nodeId) : undefined;
      const metric = channel ? CHANNEL_METRIC[channel] : undefined;
      const units = latest.get(c.device_id)?.units ?? "";
      out.push({
        deviceId: c.device_id,
        sensorId: node ? node.id : c.device_id,
        name: node ? `${node.name || node.id} · ${channel}` : c.device_id,
        zoneId,
        value: c.value,
        unit: metric?.unit ?? UNIT_TEXT[units] ?? units,
        digits: metric?.digits ?? 1,
        weight: c.weight,
        // upper row of the body band; the source core uses the lower row (no collisions)
        x: placed.cx + (i - (list.length - 1) / 2) * step,
        y: band.y0 + 12,
      });
    });
  }
  return out;
}

/**
 * Estimated source marker, attached to its room: the source zone's tile, or (an estimate known
 * only by its position) the room nearest to it in building metres, since the schematic is not to
 * scale. Inside the tile it sits in the lower row of the body band so it never covers text. (A
 * to-scale layout would map (source_x, source_y) through `toSvg`; this one never does.)
 *
 * Halo radius (uncertainty cue, NOT a statistical interval: the backend's confidence is a
 * heuristic of contributor count and spread): r = 16 + (1 - confidence) × 60 SVG units, capped
 * at 1.2x the half-diagonal of the tile (with metres: r = 0.5 m + (1 - confidence) × 3 m).
 */
export function sourceView(tri: Triangulation | undefined, incident: Incident | null, layout: Layout): SourceView | null {
  const conf = tri?.confidence ?? incident?.triangulation_confidence ?? null;
  const sx = tri?.source_x ?? incident?.est_source_x;
  const sy = tri?.source_y ?? incident?.est_source_y;
  const zoneId = tri?.source_zone_id ?? incident?.est_source_zone_id ?? null;
  if (conf == null || (!zoneId && (sx == null || sy == null))) return null;
  let placed = layout.zones.find((p) => p.zone.id === zoneId);
  if (!placed && sx != null && sy != null) {
    let best = Infinity;
    for (const p of layout.zones) {
      if (typeof p.zone.pos_x !== "number" || typeof p.zone.pos_y !== "number") continue;
      const d = Math.hypot(p.zone.pos_x - sx, p.zone.pos_y - sy);
      if (d < best) [best, placed] = [d, p];
    }
  }
  let x: number;
  let y: number;
  if (layout.toSvg && sx != null && sy != null) ({ x, y } = layout.toSvg(sx, sy));
  else if (placed) ({ x, y } = { x: placed.cx, y: placed.cy });
  else return null;
  // inside a tile: lower row of its body band
  const inside = layout.zones.find((p) => x >= p.x && x <= p.x + p.w && y >= p.y && y <= p.y + p.h);
  if (inside) {
    const band = bodyBand(inside);
    x = Math.max(band.x0 + 10, Math.min(band.x1 - 10, x));
    // lower row; the pulse ring (r ≤ 14) stays inside the body band
    const lo = band.y0 + 36;
    const hi = band.y1 - 14;
    y = lo <= hi ? Math.max(lo, Math.min(hi, y)) : (band.y0 + band.y1) / 2;
  }
  const tile = inside ?? placed;
  const raw = layout.scale ? (0.5 + (1 - conf) * 3) * layout.scale : 16 + (1 - conf) * 60;
  // visual cap: the halo is masked and clipped to the plan anyway, but a huge circle says
  // nothing more than "uncertain"
  const r = tile ? Math.min(raw, 1.2 * Math.hypot(tile.w / 2, tile.h / 2)) : raw;
  return { x, y, r, confidence: conf, zoneId: placed?.zone.id ?? zoneId, airflow: !!tri?.airflow_applied };
}

/** History window covering the incident (≥ 30 min), in 15-minute steps so the cache key stays
 *  stable between renders. */
export function incidentWindowMinutes(openedTs: string | null | undefined, now = Date.now()): number {
  if (!openedTs) return 30;
  const span = (now - parseTs(openedTs)) / 60_000;
  return Math.min(10080, Math.max(30, Math.ceil((span + 5) / 15) * 15));
}
