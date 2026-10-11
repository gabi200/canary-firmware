import { useId } from "react";
import { Area, AreaChart, ResponsiveContainer, XAxis, YAxis } from "recharts";

import type { Row } from "../lib/metrics";

/** Tiny area chart for a tile: no axes, gaps stay gaps (connectNulls off). */
export function Sparkline({
  rows,
  dataKey,
  color,
  from,
  to,
  binary,
  zeroBased,
  pad = 1,
  height = 40,
}: {
  rows: Row[];
  dataKey: string;
  color: string;
  from: number;
  to: number;
  binary?: boolean;
  zeroBased?: boolean;
  /** Margin around fitted (non zero-based) data. */
  pad?: number;
  height?: number;
}) {
  const gradient = `spark-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  if (!rows.some((r) => r[dataKey] != null)) return null;
  return (
    <ResponsiveContainer width="100%" height={height}>
      <AreaChart data={rows} margin={{ top: 3, right: 0, bottom: 0, left: 0 }}>
        <defs>
          <linearGradient id={gradient} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.45} />
            <stop offset="100%" stopColor={color} stopOpacity={0.03} />
          </linearGradient>
        </defs>
        <XAxis dataKey="t" type="number" domain={[from, to]} hide />
        <YAxis
          hide
          domain={
            binary
              ? [0, 1]
              : zeroBased
                ? [0, (max: number) => Math.max(max * 1.6, 1)] // headroom: a steady value reads as a line, not a block
                : [`dataMin - ${pad}`, `dataMax + ${pad}`]
          }
        />
        <Area
          type={binary ? "stepAfter" : "monotone"}
          dataKey={dataKey}
          stroke={color}
          strokeWidth={1.5}
          fill={`url(#${gradient})`}
          dot={false}
          activeDot={false}
          connectNulls={false}
          isAnimationActive={false}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
