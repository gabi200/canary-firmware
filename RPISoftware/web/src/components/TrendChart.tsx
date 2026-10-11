import { useMemo } from "react";
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import type { Reading } from "../api/types";
import { useT, type Lang, type MsgKey } from "../i18n";
import { fmtNumber } from "../lib/format";
import { COLORS } from "../lib/metrics";
import { useScope } from "../lib/scope";
import { fmtClock, parseTs } from "../lib/time";

export const LINE_COLORS = ["#2f81f7", "#d29922", "#2ea043", "#f85149", "#a371f7"];

/** Shared dark-theme recharts styling (also used by the sensor history charts). */
export const chartStyle = {
  grid: "#2c3846",
  axis: "#8b98a8",
  tooltip: {
    contentStyle: { background: "#1a212b", border: "1px solid #2c3846", borderRadius: 8 },
    labelStyle: { color: "#8b98a8" },
  },
};

/** Rotated unit caption for a YAxis `label`. */
export function axisUnit(unit: string, side: "left" | "right" = "left") {
  return {
    value: unit,
    angle: side === "left" ? -90 : 90,
    position: side === "left" ? ("insideLeft" as const) : ("insideRight" as const),
    fill: chartStyle.axis,
    fontSize: 11,
  };
}

/** Display form of reading units ("adc" is a raw MQ5 count from the hardware, not ppm). */
const UNIT_TEXT: Record<string, string> = { adc: "ADC", "ug/m3": "µg/m³" };
const UNIT_CAPTION: Record<string, MsgKey> = { adc: "trend.adcCaption" };

/** One line per group (e.g. apartment) instead of one per device: the highest reading of the
 *  group's devices in each time bucket. */
export interface TrendGroups {
  /** group id of a reading; null leaves it out */
  of: (r: Reading) => string | null;
  /** every group in display order, each with its own stable colour */
  series: { id: string; label: string; color: string }[];
}

/** Air nodes report every 15 s: a 30 s bucket holds each device's reading at least once. */
const BUCKET_MS = 30_000;
const MAX_BUCKETS = 48;

type ChartRow = Record<string, number | string>;
const seriesKey = (id: string) => `g_${id.replace(/\W/g, "_")}`;

/** Max per bucket and group; rows sorted by time, `t` = clock label of the bucket start. */
function bucketRows(readings: Reading[], groups: TrendGroups, lang: Lang): ChartRow[] {
  const pts: { t: number; key: string; v: number }[] = [];
  for (const r of readings) {
    const id = groups.of(r);
    const t = parseTs(r.ts);
    if (id != null && Number.isFinite(t) && Number.isFinite(r.value)) pts.push({ t, key: seriesKey(id), v: r.value });
  }
  if (!pts.length) return [];
  const t0 = Math.min(...pts.map((p) => p.t));
  const span = Math.max(...pts.map((p) => p.t)) - t0;
  const size = Math.max(BUCKET_MS, Math.ceil(span / MAX_BUCKETS / 15_000) * 15_000);
  // the readings limit cuts the oldest bucket short (some devices missing): drop it once there is history
  let start = Math.floor(t0 / size) * size;
  if (start < t0 && span > 4 * size) start += size;

  const rows = new Map<number, ChartRow>();
  for (const p of pts) {
    if (p.t < start) continue;
    const b = start + Math.floor((p.t - start) / size) * size;
    const row = rows.get(b) ?? { t: fmtClock(b, lang, size < 60_000) };
    const cur = row[p.key];
    if (typeof cur !== "number" || p.v > cur) row[p.key] = p.v;
    rows.set(b, row);
  }
  return [...rows.entries()].sort((a, b) => a[0] - b[0]).map(([, row]) => row);
}

/** Wide-format line chart, all in one unit: one line per device, or per group with `groups`. */
function UnitTrend({
  readings,
  unit,
  height,
  groups,
}: {
  readings: Reading[];
  unit: string;
  height: number;
  groups?: TrendGroups;
}) {
  const { t, lang } = useT();
  const unitText = UNIT_TEXT[unit] ?? unit;

  let data: ChartRow[];
  let lines: { key: string; name: string; color: string }[];
  if (groups) {
    data = bucketRows(readings, groups, lang);
    const present = new Set(data.flatMap((row) => Object.keys(row)));
    lines = groups.series
      .filter((s) => present.has(seriesKey(s.id)))
      .map((s) => ({ key: seriesKey(s.id), name: s.label, color: s.color }));
  } else {
    const devices = Array.from(new Set(readings.map((r) => r.device_id)));
    const sorted = [...readings].sort((a, b) => a.ts.localeCompare(b.ts));
    const rows = new Map<string, ChartRow>();
    for (const r of sorted) {
      // fmtClock reads zone-less backend timestamps as UTC (SQLite)
      const row = rows.get(r.ts) ?? { t: fmtClock(r.ts, lang) };
      row[r.device_id] = r.value;
      rows.set(r.ts, row);
    }
    data = Array.from(rows.values());
    lines = devices.map((dev, i) => ({ key: dev, name: dev, color: LINE_COLORS[i % LINE_COLORS.length] }));
  }
  if (!lines.length) return <div className="muted small">{t("trend.noReadings")}</div>;

  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
        <CartesianGrid stroke={chartStyle.grid} strokeDasharray="3 3" />
        <XAxis dataKey="t" stroke={chartStyle.axis} fontSize={11} minTickGap={28} />
        <YAxis
          stroke={chartStyle.axis}
          fontSize={11}
          label={axisUnit(unitText)}
          tickFormatter={(v: number) => fmtNumber(v, lang, 1)}
        />
        <Tooltip
          {...chartStyle.tooltip}
          formatter={(v) => (typeof v === "number" ? `${fmtNumber(v, lang, 1)} ${unitText}` : "—")}
        />
        {groups && <Legend iconType="plainline" wrapperStyle={{ fontSize: 12, color: chartStyle.axis }} />}
        {lines.map((l) => (
          <Line
            key={l.key}
            type="monotone"
            dataKey={l.key}
            name={l.name}
            stroke={l.color}
            dot={false}
            strokeWidth={2}
            connectNulls
            isAnimationActive={false}
          />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}

/**
 * Readings of one sensor type can arrive in different units (hardware MQ5 gas in raw ADC
 * counts, simulated sensors in ppm). Units never share an axis: one chart per unit.
 */
export function TrendChart({
  readings,
  height = 200,
  groups,
}: {
  readings: Reading[];
  height?: number;
  groups?: TrendGroups;
}) {
  const { t } = useT();
  if (readings.length === 0) {
    return <div className="muted small">{t("trend.noReadings")}</div>;
  }
  const units = Array.from(new Set(readings.map((r) => r.units)));
  if (units.length === 1) return <UnitTrend readings={readings} unit={units[0]} height={height} groups={groups} />;
  return (
    <>
      {units.map((u) => (
        <div key={u} className="trend-unit">
          <div className="muted small">{UNIT_CAPTION[u] ? t(UNIT_CAPTION[u]) : UNIT_TEXT[u] ?? u}</div>
          <UnitTrend
            readings={readings.filter((r) => r.units === u)}
            unit={u}
            height={Math.round(height * 0.7)}
            groups={groups}
          />
        </div>
      ))}
    </>
  );
}

/** Apartment colours by position (apartments in natural order); common areas stay grey. Red,
 *  amber and green are left out: on this dashboard they mean danger, attention and OK. */
const UNIT_COLORS = [COLORS.blue, COLORS.orange, COLORS.purple, COLORS.cyan, COLORS.magenta, COLORS.teal, COLORS.sky];

/** TrendChart with one line per apartment (the highest reading of its devices), in the scope
 *  bar's order; a reading's room (`zone_id`) gives its apartment. */
export function ApartmentTrendChart({ readings, height }: { readings: Reading[]; height?: number }) {
  const { units, rooms } = useScope();
  const groups = useMemo<TrendGroups>(() => {
    const unitOf = new Map(rooms.map((r) => [r.id, r.unitId]));
    let apt = 0;
    return {
      of: (r) => unitOf.get(r.zone_id) ?? null,
      series: units.map((u) => ({
        id: u.id,
        label: u.label,
        color: u.common ? COLORS.muted : UNIT_COLORS[apt++ % UNIT_COLORS.length],
      })),
    };
  }, [units, rooms]);
  return <TrendChart readings={readings} height={height} groups={groups} />;
}
