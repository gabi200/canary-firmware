import { useState } from "react";
import {
  Area,
  CartesianGrid,
  ComposedChart,
  Legend,
  Line,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import { useNodeHistory } from "../api/hooks";
import type { NodeHistory, NodeOut } from "../api/types";
import { fmtNum, pickNum } from "../lib/nodes";
import { fmtClock, parseTs } from "../lib/time";
import { axisUnit, chartStyle } from "./TrendChart";

const RANGES = [
  { minutes: 15, label: "15 min" },
  { minutes: 60, label: "1 h" },
  { minutes: 360, label: "6 h" },
  { minutes: 1440, label: "24 h" },
];

const C = {
  blue: "#2f81f7",
  purple: "#a371f7",
  cyan: "#39c5cf",
  orange: "#f0883e",
  green: "#2ea043",
  amber: "#d29922",
  red: "#f85149",
};

interface Series {
  field: string;
  label: string;
  color: string;
  right?: boolean;
}

interface ChartSpec {
  title: string;
  unit: string;
  rightUnit?: string;
  note?: string;
  series: Series[];
  /** Device thresholds from the latest raw document, drawn as dashed lines. */
  refs?: { label: string; path: string; color: string }[];
  /** Stretch the axis so the thresholds are always visible (otherwise drawn only in range). */
  showRefs?: boolean;
  /** Axis fits the data instead of starting at 0. */
  fit?: boolean;
  /** 0/1 signal drawn as a step area. */
  binary?: boolean;
  wide?: boolean;
}

const AIR_CHARTS: ChartSpec[] = [
  {
    title: "Carbon monoxide",
    unit: "ppm",
    series: [{ field: "co.ppm", label: "CO", color: C.blue }],
    refs: [
      { label: "warn", path: "co.warn_ppm", color: C.amber },
      { label: "danger", path: "co.danger_ppm", color: C.red },
    ],
  },
  {
    title: "Combustible gas (MQ5)",
    unit: "ADC",
    note: "raw ADC count, not ppm",
    series: [{ field: "gas.adc", label: "Gas", color: C.purple }],
    refs: [
      { label: "warn", path: "gas.warn_adc", color: C.amber },
      { label: "danger", path: "gas.danger_adc", color: C.red },
    ],
  },
  {
    title: "Particulates",
    unit: "µg/m³",
    series: [
      { field: "particulate.pm1_0", label: "PM1.0", color: C.cyan },
      { field: "particulate.pm2_5", label: "PM2.5", color: C.blue },
      { field: "particulate.pm10", label: "PM10", color: C.purple },
    ],
    refs: [
      { label: "PM2.5 warn", path: "particulate.warn_pm2_5", color: C.amber },
      { label: "PM2.5 danger", path: "particulate.danger_pm2_5", color: C.red },
    ],
  },
  {
    title: "Temperature / humidity",
    unit: "°C",
    rightUnit: "%RH",
    fit: true,
    series: [
      { field: "climate.temperature_c", label: "Temperature", color: C.orange },
      { field: "climate.humidity_percent", label: "Humidity", color: C.blue, right: true },
    ],
  },
  {
    title: "Presence (radar)",
    unit: "",
    binary: true,
    wide: true,
    series: [{ field: "presence.detected", label: "Presence", color: C.green }],
  },
];

const WATER_CHARTS: ChartSpec[] = [
  {
    title: "Leak sensor",
    unit: "ADC",
    wide: true,
    showRefs: true,
    series: [{ field: "sensor.adc", label: "Sensor", color: C.blue }],
    refs: [
      { label: "wet ≥", path: "sensor.wet_threshold", color: C.red },
      { label: "dry ≤", path: "sensor.dry_threshold", color: C.green },
    ],
  },
  {
    title: "Leak latch",
    unit: "",
    binary: true,
    wide: true,
    series: [{ field: "leak_latched", label: "Latched", color: C.red }],
  },
];

/** Stale thresholds from the contract (3x heartbeat): longer silences are drawn as gaps. */
const STALE_MS = { air: 45_000, water: 180_000 };

const TICK_STEPS_MIN = [1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 360];

/** At most ~5 axis ticks on round local clock times (recharts would space them by raw ms). */
function timeTicks(from: number, to: number): number[] {
  const stepMin = TICK_STEPS_MIN.find((m) => (to - from) / (m * 60_000) <= 5) ?? 360;
  const step = stepMin * 60_000;
  const tz = new Date(from).getTimezoneOffset() * 60_000;
  const ticks: number[] = [];
  for (let t = Math.ceil((from - tz) / step) * step + tz; t <= to; t += step) ticks.push(t);
  return ticks;
}

/** recharts reads dotted dataKeys as nested paths, so chart rows use flat keys. */
const keyOf = (field: string) => field.replace(/\W/g, "_");

type Row = Record<string, number | null>;

/** Chart rows (t = epoch ms). A blank row is inserted wherever reports stop for longer than
 *  the stale threshold (or 3x the typical spacing of downsampled points), so outages show
 *  as gaps rather than straight lines. */
function toRows(points: NodeHistory["points"], fields: string[], staleMs: number): Row[] {
  const pts = points
    .map((p) => ({ t: parseTs(p.ts), values: p.values ?? {} }))
    .filter((p) => Number.isFinite(p.t));
  const steps = pts
    .slice(1)
    .map((p, i) => p.t - pts[i].t)
    .sort((a, b) => a - b);
  const gapMs = Math.max(staleMs, 3 * (steps[Math.floor(steps.length / 2)] ?? 0));

  const rows: Row[] = [];
  let prev: number | null = null;
  for (const p of pts) {
    if (prev != null && p.t - prev > gapMs) {
      const blank: Row = { t: prev + 1 };
      for (const f of fields) blank[keyOf(f)] = null;
      rows.push(blank);
    }
    const row: Row = { t: p.t };
    for (const f of fields) {
      const v = p.values[f];
      row[keyOf(f)] = typeof v === "number" ? v : null;
    }
    rows.push(row);
    prev = p.t;
  }
  return rows;
}

function HistoryChart({
  spec,
  rows,
  from,
  to,
  doc,
}: {
  spec: ChartSpec;
  rows: Row[];
  from: number;
  to: number;
  doc: unknown;
}) {
  const refs = (spec.refs ?? []).flatMap((r) => {
    const value = pickNum(doc, r.path);
    return value == null ? [] : [{ ...r, value }];
  });
  const hasData = rows.some((row) => spec.series.some((s) => row[keyOf(s.field)] != null));
  const unitOf = new Map(
    spec.series.map((s) => [keyOf(s.field), s.right ? spec.rightUnit : spec.unit]),
  );

  return (
    <div className={`chart ${spec.wide ? "wide" : ""}`}>
      <div className="chart-head">
        <span className="chart-title">{spec.title}</span>
        {spec.note && <span className="muted small">{spec.note}</span>}
        <span className="spacer" />
        {refs.length > 0 && (
          <span className="muted small">
            {refs.map((r) => `${r.label} ${fmtNum(r.value)}`).join(" · ")}
          </span>
        )}
      </div>
      {!hasData ? (
        <div className="chart-empty muted small">No data in this range.</div>
      ) : (
        <ResponsiveContainer width="100%" height={spec.binary ? 80 : 180}>
          <ComposedChart data={rows} margin={{ top: 8, right: spec.rightUnit ? 0 : 12, bottom: 0, left: 0 }}>
            <CartesianGrid stroke={chartStyle.grid} strokeDasharray="3 3" />
            <XAxis
              dataKey="t"
              type="number"
              scale="time"
              domain={[from, to]}
              ticks={timeTicks(from, to)}
              tickFormatter={(t: number) =>
                new Date(t).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              }
              stroke={chartStyle.axis}
              fontSize={11}
              minTickGap={40}
            />
            <YAxis
              yAxisId="left"
              stroke={chartStyle.axis}
              fontSize={11}
              width={spec.binary ? 44 : 56}
              domain={spec.binary ? [0, 1] : spec.fit ? ["auto", "auto"] : [0, "auto"]}
              ticks={spec.binary ? [0, 1] : undefined}
              tickFormatter={spec.binary ? (v: number) => (v ? "yes" : "no") : undefined}
              label={spec.unit ? axisUnit(spec.unit) : undefined}
            />
            {spec.rightUnit && (
              <YAxis
                yAxisId="right"
                orientation="right"
                stroke={chartStyle.axis}
                fontSize={11}
                width={56}
                domain={["auto", "auto"]}
                label={axisUnit(spec.rightUnit, "right")}
              />
            )}
            <Tooltip
              {...chartStyle.tooltip}
              labelFormatter={(t) => fmtClock(Number(t))}
              formatter={(v, _name, item) => {
                if (typeof v !== "number") return "—";
                if (spec.binary) return v ? "yes" : "no";
                return `${fmtNum(v)} ${unitOf.get(String(item.dataKey)) ?? ""}`;
              }}
            />
            {spec.series.length > 1 && <Legend wrapperStyle={{ fontSize: 12 }} />}
            {refs.map((r) => (
              <ReferenceLine
                key={r.label}
                yAxisId="left"
                y={r.value}
                stroke={r.color}
                strokeDasharray="5 4"
                ifOverflow={spec.showRefs ? "extendDomain" : "discard"}
                label={{ value: r.label, fill: r.color, fontSize: 10, position: "insideTopRight" }}
              />
            ))}
            {spec.series.map((s) =>
              spec.binary ? (
                <Area
                  key={s.field}
                  yAxisId="left"
                  type="stepAfter"
                  dataKey={keyOf(s.field)}
                  name={s.label}
                  stroke={s.color}
                  fill={s.color}
                  fillOpacity={0.25}
                  isAnimationActive={false}
                />
              ) : (
                <Line
                  key={s.field}
                  yAxisId={s.right ? "right" : "left"}
                  type="monotone"
                  dataKey={keyOf(s.field)}
                  name={s.label}
                  stroke={s.color}
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
              ),
            )}
          </ComposedChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}

/** Raw history charts of one node from GET /nodes/{id}/history, with a range selector. */
export function NodeHistoryCharts({ node }: { node: NodeOut }) {
  const [minutes, setMinutes] = useState(60);
  const specs = node.kind === "water" ? WATER_CHARTS : AIR_CHARTS;
  const fields = specs.flatMap((c) => c.series.map((s) => s.field));
  const history = useNodeHistory(node.id, minutes, fields);

  const data = history.data;
  // the window actually shown (previous range stays up while a new one loads)
  const to = history.dataUpdatedAt || Date.now();
  const from = to - (data?.minutes ?? minutes) * 60_000;
  const rows = data ? toRows(data.points ?? [], fields, STALE_MS[node.kind] ?? 45_000) : [];

  return (
    <div className="node-charts">
      <div className="charts-head">
        <span className="panel-label">Raw history</span>
        <div className="seg">
          {RANGES.map((r) => (
            <button
              key={r.minutes}
              className={r.minutes === minutes ? "active" : ""}
              onClick={() => setMinutes(r.minutes)}
            >
              {r.label}
            </button>
          ))}
        </div>
        {history.isFetching && <span className="muted small">updating…</span>}
      </div>
      {history.isError && !data ? (
        <div className="err">History unavailable: {(history.error as Error).message}</div>
      ) : !data ? (
        <div className="muted small">Loading history…</div>
      ) : (
        <div className="charts">
          {specs.map((spec) => (
            <HistoryChart key={spec.title} spec={spec} rows={rows} from={from} to={to} doc={node.status} />
          ))}
        </div>
      )}
    </div>
  );
}
