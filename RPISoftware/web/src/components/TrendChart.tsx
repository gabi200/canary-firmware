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

const LINE_COLORS = ["#2f81f7", "#d29922", "#2ea043", "#f85149", "#a371f7"];

function fmt(ts: string): string {
  const d = new Date(ts);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

/** Wide-format line chart: one line per device for the given readings. */
export function TrendChart({ readings, height = 200 }: { readings: Reading[]; height?: number }) {
  if (readings.length === 0) {
    return <div className="muted small">No readings yet.</div>;
  }

  const devices = Array.from(new Set(readings.map((r) => r.device_id)));
  const sorted = [...readings].sort((a, b) => a.ts.localeCompare(b.ts));

  const rows = new Map<string, Record<string, number | string>>();
  for (const r of sorted) {
    const row = rows.get(r.ts) ?? { t: fmt(r.ts) };
    row[r.device_id] = r.value;
    rows.set(r.ts, row);
  }
  const data = Array.from(rows.values());

  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: -12 }}>
        <CartesianGrid stroke="#2c3846" strokeDasharray="3 3" />
        <XAxis dataKey="t" stroke="#8b98a8" fontSize={11} minTickGap={28} />
        <YAxis stroke="#8b98a8" fontSize={11} />
        <Tooltip
          contentStyle={{ background: "#1a212b", border: "1px solid #2c3846", borderRadius: 8 }}
          labelStyle={{ color: "#8b98a8" }}
        />
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
