import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import type { Reading } from "../api/types";
import { parseTs } from "../lib/time";

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
const UNIT_CAPTION: Record<string, string> = { adc: "Raw MQ5 ADC counts (hardware, not ppm)" };

function fmt(ts: string): string {
  const d = new Date(parseTs(ts)); // UTC even when the backend (SQLite) omits the zone
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

/** Wide-format line chart: one line per device, all in one unit. */
function UnitTrend({ readings, unit, height }: { readings: Reading[]; unit: string; height: number }) {
  const devices = Array.from(new Set(readings.map((r) => r.device_id)));
  const sorted = [...readings].sort((a, b) => a.ts.localeCompare(b.ts));
  const unitText = UNIT_TEXT[unit] ?? unit;

  const rows = new Map<string, Record<string, number | string>>();
  for (const r of sorted) {
    const row = rows.get(r.ts) ?? { t: fmt(r.ts) };
    row[r.device_id] = r.value;
    rows.set(r.ts, row);
  }
  const data = Array.from(rows.values());

  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
        <CartesianGrid stroke={chartStyle.grid} strokeDasharray="3 3" />
        <XAxis dataKey="t" stroke={chartStyle.axis} fontSize={11} minTickGap={28} />
        <YAxis stroke={chartStyle.axis} fontSize={11} label={axisUnit(unitText)} />
        <Tooltip {...chartStyle.tooltip} formatter={(v) => `${v} ${unitText}`} />
        {devices.map((dev, i) => (
          <Line
            key={dev}
            type="monotone"
            dataKey={dev}
            stroke={LINE_COLORS[i % LINE_COLORS.length]}
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
export function TrendChart({ readings, height = 200 }: { readings: Reading[]; height?: number }) {
  if (readings.length === 0) {
    return <div className="muted small">No readings yet.</div>;
  }
  const units = Array.from(new Set(readings.map((r) => r.units)));
  if (units.length === 1) return <UnitTrend readings={readings} unit={units[0]} height={height} />;
  return (
    <>
      {units.map((u) => (
        <div key={u} className="trend-unit">
          <div className="muted small">{UNIT_CAPTION[u] ?? UNIT_TEXT[u] ?? u}</div>
          <UnitTrend
            readings={readings.filter((r) => r.units === u)}
            unit={u}
            height={Math.round(height * 0.7)}
          />
        </div>
      ))}
    </>
  );
}
