/**
 * What the sensor nodes really measure (docs/HARDWARE.md §1), for the live tiles and the
 * history charts: field paths, units, display precision, the device's own thresholds and
 * how a value is graded against them. Nothing here invents a threshold the hardware lacks.
 */
import type { AnalysisLevel, NodeHistory, NodeKind } from "../api/types";
import type { MsgKey } from "../i18n";
import { pick, pickNum } from "./nodes";
import { parseTs } from "./time";

/** `none`: the hardware has no threshold for this metric (neutral colour, never graded). */
export type Level = AnalysisLevel | "none";

export const COLORS = {
  blue: "#2f81f7",
  sky: "#58a6ff",
  purple: "#a371f7",
  cyan: "#39c5cf",
  teal: "#56d4bc",
  orange: "#f0883e",
  magenta: "#db61a2",
  green: "#2ea043",
  amber: "#d29922",
  red: "#f85149",
  muted: "#8b98a8",
};

export const LEVEL_COLOR: Record<Level, string> = {
  ok: COLORS.green,
  attention: COLORS.amber,
  danger: COLORS.red,
  unknown: COLORS.muted,
  none: COLORS.blue,
};

/** recharts reads dotted dataKeys as nested paths, so chart rows use flat keys. */
export const keyOf = (field: string) => field.replace(/\W/g, "_");

/** History fields per node kind (backend limit: 16 per request). Thresholds are read from
 *  the latest status document instead: they are the installer calibration, not a signal. */
export const HISTORY_FIELDS: Record<NodeKind, string[]> = {
  air: [
    "co.ppm",
    "gas.adc",
    "particulate.pm1_0",
    "particulate.pm2_5",
    "particulate.pm10",
    "climate.temperature_c",
    "climate.humidity_percent",
    "wifi.rssi",
    "presence.detected",
    "presence.moving",
    "presence.stationary",
    "uptime_ms",
  ],
  water: ["sensor.adc", "leak_latched", "sensor.state", "valve.applied", "wifi.rssi", "uptime_ms"],
};

/** Text fields drawn as 0/1 step timelines (anything else, e.g. "uninitialized", is a gap). */
const TEXT_AS_FLAG: Record<string, Record<string, number>> = {
  "valve.applied": { open: 0, closed: 1 },
  "sensor.state": { dry: 0, wet: 1 },
};

/** 0/1 fields; a bucketed value above 0 means "at some point in that slot". */
const FLAG_FIELDS = new Set([
  "presence.detected",
  "presence.moving",
  "presence.stationary",
  "leak_latched",
  ...Object.keys(TEXT_AS_FLAG),
]);

export type Row = Record<string, number | null>;

/** Contract heartbeats x3: longer silences are drawn as gaps, never as connecting lines. */
const STALE_MS: Record<NodeKind, number> = { air: 45_000, water: 180_000 };

function numeric(field: string, v: number | string | null | undefined): number | null {
  if (typeof v === "string") return TEXT_AS_FLAG[field]?.[v] ?? null;
  if (typeof v !== "number" || !Number.isFinite(v)) return null;
  return FLAG_FIELDS.has(field) ? (v > 0 ? 1 : 0) : v;
}

/** Chart rows (t = epoch ms). Null values (offline, warm-up, fault, invalid) stay null, and a
 *  blank row is inserted wherever reports stop for longer than the stale threshold (or 3x
 *  the typical spacing of aggregated points), so outages show as gaps. */
export function toRows(points: NodeHistory["points"], fields: string[], kind: NodeKind): Row[] {
  const pts = points
    .map((p) => ({ t: parseTs(p.ts), values: p.values ?? {} }))
    .filter((p) => Number.isFinite(p.t));
  const steps = pts
    .slice(1)
    .map((p, i) => p.t - pts[i].t)
    .sort((a, b) => a - b);
  const gapMs = Math.max(STALE_MS[kind] ?? 45_000, 3 * (steps[Math.floor(steps.length / 2)] ?? 0));

  const rows: Row[] = [];
  let prev: number | null = null;
  for (const p of pts) {
    if (prev != null && p.t - prev > gapMs) {
      const blank: Row = { t: prev + 1 };
      for (const f of fields) blank[keyOf(f)] = null;
      rows.push(blank);
    }
    const row: Row = { t: p.t };
    for (const f of fields) row[keyOf(f)] = numeric(f, p.values[f]);
    rows.push(row);
    prev = p.t;
  }
  return rows;
}

export interface Stats {
  min: number;
  avg: number;
  max: number;
  n: number;
}

/** Min / mean / max of the non-null values of one row key (null when there is no data). */
export function stats(rows: Row[], key: string): Stats | null {
  let n = 0;
  let sum = 0;
  let min = Infinity;
  let max = -Infinity;
  for (const r of rows) {
    const v = r[key];
    if (v == null) continue;
    n += 1;
    sum += v;
    if (v < min) min = v;
    if (v > max) max = v;
  }
  return n ? { min, avg: sum / n, max, n } : null;
}

/** Boot instants in the window: wherever uptime_ms drops the device restarted, about
 *  uptime_ms before that report (clamped between the two reports). */
export function rebootTimes(points: NodeHistory["points"]): number[] {
  const out: number[] = [];
  let prev: { t: number; up: number } | null = null;
  for (const p of points) {
    const t = parseTs(p.ts);
    const up = p.values?.uptime_ms;
    if (typeof up !== "number" || !Number.isFinite(t)) continue;
    if (prev && up < prev.up) out.push(Math.max(prev.t, Math.min(t, t - up)));
    prev = { t, up };
  }
  return out;
}

/** Whether a channel's current measurement can be trusted (status document flags). */
export type Trust = "ok" | "warmup" | "fault" | "invalid" | "uninitialized" | "missing";

export function channelTrust(doc: unknown, channel?: string): Trust {
  if (doc == null) return "missing";
  if (!channel) return "ok";
  const c = pick(doc, channel);
  if (c === null || typeof c !== "object") return "ok";
  const o = c as Record<string, unknown>;
  if (o.state === "warmup") return "warmup";
  if (o.state === "fault") return "fault";
  if (o.state === "uninitialized" || o.initialized === false) return "uninitialized";
  if (o.valid === false) return "invalid";
  return "ok";
}

/** Firmware grading: value >= danger is danger, >= warn is warning. */
export function thresholdLevel(v: number, doc: unknown, warn: string, danger: string): Level {
  const d = pickNum(doc, danger);
  const w = pickNum(doc, warn);
  if (d == null && w == null) return "none";
  return d != null && v >= d ? "danger" : w != null && v >= w ? "attention" : "ok";
}

/** Water probe: wet at >= wet_threshold, dry at <= dry_threshold, in between it holds. */
function probeLevel(v: number, doc: unknown): Level {
  const wet = pickNum(doc, "sensor.wet_threshold");
  const dry = pickNum(doc, "sensor.dry_threshold");
  if (wet == null && dry == null) return "none";
  return wet != null && v >= wet ? "danger" : dry != null && v > dry ? "attention" : "ok";
}

/** Conventional Wi-Fi bands (a dashboard heuristic, not a device threshold). */
export function rssiQuality(dbm: number): "good" | "fair" | "weak" {
  return dbm >= -67 ? "good" : dbm >= -80 ? "fair" : "weak";
}

export interface Ref {
  path: string;
  tone: "warn" | "danger";
  label: MsgKey;
}

export interface Metric {
  field: string;
  label: MsgKey;
  unit: string;
  /** Decimals shown (`fixed`: always that many). */
  digits: number;
  fixed?: boolean;
  /** Approximate by construction (climate inside the PMS5003T): shown with "≈". */
  approx?: boolean;
  /** Status-document object whose state / valid / initialized gate the value. */
  channel?: string;
  /** The device's own thresholds (dashed reference lines). */
  refs?: Ref[];
  level: (v: number, doc: unknown) => Level;
  color: string;
  /** Axis starts at 0 (concentrations, counts) instead of fitting the data. */
  zeroBased?: boolean;
  /** Fitted axes: margin around the data, so sensor noise does not look like a swing. */
  pad?: number;
  /** Tooltip explaining what the number is (and is not). */
  hint?: MsgKey;
}

const WARN_DANGER = (warn: string, danger: string): Pick<Metric, "refs" | "level"> => ({
  refs: [
    { path: warn, tone: "warn", label: "threshold.warn" },
    { path: danger, tone: "danger", label: "threshold.danger" },
  ],
  level: (v, doc) => thresholdLevel(v, doc, warn, danger),
});

const NONE = () => "none" as const;

export const METRICS = {
  co: {
    field: "co.ppm",
    label: "sensor.co",
    unit: "ppm",
    digits: 0,
    channel: "co",
    color: COLORS.blue,
    zeroBased: true,
    hint: "tile.coHint",
    ...WARN_DANGER("co.warn_ppm", "co.danger_ppm"),
  },
  pm25: {
    field: "particulate.pm2_5",
    label: "tile.pm25",
    unit: "µg/m³",
    digits: 0,
    channel: "particulate",
    color: COLORS.cyan,
    zeroBased: true,
    ...WARN_DANGER("particulate.warn_pm2_5", "particulate.danger_pm2_5"),
  },
  pm10: {
    field: "particulate.pm10",
    label: "tile.pm10",
    unit: "µg/m³",
    digits: 0,
    channel: "particulate",
    color: COLORS.purple,
    zeroBased: true,
    ...WARN_DANGER("particulate.warn_pm10", "particulate.danger_pm10"),
  },
  pm1: {
    field: "particulate.pm1_0",
    label: "tile.pm1",
    unit: "µg/m³",
    digits: 0,
    channel: "particulate",
    color: COLORS.teal,
    zeroBased: true,
    level: NONE,
  },
  temperature: {
    field: "climate.temperature_c",
    label: "tile.temperature",
    unit: "°C",
    digits: 1,
    fixed: true,
    approx: true,
    channel: "climate",
    color: COLORS.orange,
    pad: 1,
    hint: "tile.climateHint",
    level: NONE,
  },
  humidity: {
    field: "climate.humidity_percent",
    label: "tile.humidity",
    unit: "%",
    digits: 1,
    fixed: true,
    approx: true,
    channel: "climate",
    color: COLORS.sky,
    pad: 2,
    hint: "tile.climateHint",
    level: NONE,
  },
  gas: {
    field: "gas.adc",
    label: "tile.gas",
    unit: "ADC",
    digits: 0,
    channel: "gas",
    color: COLORS.magenta,
    zeroBased: true,
    hint: "tile.gasHint",
    ...WARN_DANGER("gas.warn_adc", "gas.danger_adc"),
  },
  rssi: {
    field: "wifi.rssi",
    label: "tile.rssi",
    unit: "dBm",
    digits: 0,
    color: COLORS.sky,
    pad: 3,
    hint: "tile.rssiHint",
    level: (v) => (rssiQuality(v) === "weak" ? "attention" : "ok"),
  },
  probe: {
    field: "sensor.adc",
    label: "tile.probe",
    unit: "ADC",
    digits: 0,
    channel: "sensor",
    color: COLORS.blue,
    zeroBased: true,
    hint: "tile.probeHint",
    refs: [
      { path: "sensor.dry_threshold", tone: "warn", label: "threshold.dry" },
      { path: "sensor.wet_threshold", tone: "danger", label: "threshold.wet" },
    ],
    level: probeLevel,
  },
} satisfies Record<string, Metric>;

export type MetricId = keyof typeof METRICS;

/** Current value of a metric from the latest status document, gated by its channel. */
export function currentValue(m: Metric, doc: unknown): { value: number | null; trust: Trust } {
  const trust = channelTrust(doc, m.channel);
  return { value: trust === "ok" ? pickNum(doc, m.field) : null, trust };
}
