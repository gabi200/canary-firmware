import {
  Area,
  AreaChart,
  CartesianGrid,
  ComposedChart,
  Line,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import type { NodeOut } from "../api/types";
import { useT, type MsgKey } from "../i18n";
import { fmtNumber } from "../lib/format";
import { COLORS, METRICS, keyOf, stats, type Metric, type Ref, type Row } from "../lib/metrics";
import { pickNum } from "../lib/nodes";
import { fmtAxisTime, fmtTooltipTime, timeTicks } from "../lib/time";
import { axisUnit, chartStyle } from "./TrendChart";

interface Series {
  metric: Metric;
  /** Short legend / tooltip name. */
  name: MsgKey;
  right?: boolean;
}

interface ChartSpec {
  id: string;
  title: MsgKey;
  note?: MsgKey;
  series: Series[];
  /** Device thresholds (left axis), always kept in view. */
  refs?: Ref[];
  wide?: boolean;
}

interface TimelineSpec {
  id: string;
  title: MsgKey;
  note?: MsgKey;
  items: { field: string; label: MsgKey; color: string }[];
}

const AIR_CHARTS: ChartSpec[] = [
  { id: "co", title: "chart.co", series: [{ metric: METRICS.co, name: "metric.co" }], refs: METRICS.co.refs },
  {
    id: "fine",
    title: "chart.fineParticles",
    series: [
      { metric: METRICS.pm1, name: "metric.pm1" },
      { metric: METRICS.pm25, name: "metric.pm25" },
    ],
    refs: METRICS.pm25.refs,
  },
  { id: "pm10", title: "tile.pm10", series: [{ metric: METRICS.pm10, name: "metric.pm10" }], refs: METRICS.pm10.refs },
  {
    id: "gas",
    title: "tile.gas",
    note: "chart.gasNote",
    series: [{ metric: METRICS.gas, name: "metric.gas" }],
    refs: METRICS.gas.refs,
  },
  {
    id: "climate",
    title: "chart.climate",
    note: "chart.climateNote",
    series: [
      { metric: METRICS.temperature, name: "metric.temperature" },
      { metric: METRICS.humidity, name: "metric.humidity", right: true },
    ],
  },
  { id: "rssi", title: "tile.rssi", series: [{ metric: METRICS.rssi, name: "tile.rssi" }] },
];

const AIR_TIMELINE: TimelineSpec = {
  id: "presence",
  title: "chart.presence",
  note: "chart.presenceNote",
  items: [
    { field: "presence.detected", label: "timeline.detected", color: COLORS.green },
    { field: "presence.moving", label: "raw.movingTarget", color: COLORS.cyan },
    { field: "presence.stationary", label: "raw.stationaryTarget", color: COLORS.purple },
  ],
};

const WATER_CHARTS: ChartSpec[] = [
  {
    id: "probe",
    title: "tile.probe",
    series: [{ metric: METRICS.probe, name: "metric.sensor" }],
    refs: METRICS.probe.refs,
  },
  { id: "rssi", title: "tile.rssi", series: [{ metric: METRICS.rssi, name: "tile.rssi" }] },
];

const WATER_TIMELINE: TimelineSpec = {
  id: "water",
  title: "timeline.water",
  items: [
    { field: "sensor.state", label: "timeline.probeWet", color: COLORS.red },
    { field: "leak_latched", label: "raw.leakLatched", color: COLORS.orange },
    { field: "valve.applied", label: "timeline.valveClosed", color: COLORS.amber },
  ],
};

const REF_COLOR = { warn: COLORS.amber, danger: COLORS.red };

/** 0-based for concentrations / counts, else the data plus the metric's margin. */
const domainOf = (m: Metric): [number | string, number | string] =>
  m.zeroBased ? [0, "auto"] : [`dataMin - ${m.pad ?? 0}`, `dataMax + ${m.pad ?? 0}`];
const REBOOT_COLOR = "#a371f7";

interface Window {
  rows: Row[];
  from: number;
  to: number;
  minutes: number;
  reboots: number[];
}

function MetricChart({ spec, doc, win }: { spec: ChartSpec; doc: unknown; win: Window }) {
  const { t, lang } = useT();
  const { rows, from, to, minutes } = win;
  const refs = (spec.refs ?? []).flatMap((r) => {
    const value = pickNum(doc, r.path);
    return value == null ? [] : [{ ...r, value }];
  });
  const left = spec.series.find((s) => !s.right)!.metric;
  const right = spec.series.find((s) => s.right)?.metric;
  const byKey = new Map(spec.series.map((s) => [keyOf(s.metric.field), s.metric]));
  const summaries = spec.series.map((s) => ({ s, st: stats(rows, keyOf(s.metric.field)) }));
  const hasData = summaries.some((x) => x.st);
  const reboots = win.reboots.filter((r) => r >= from && r <= to);
  const num = (m: Metric, v: number, extra = 0) => fmtNumber(v, lang, m.digits + extra, m.fixed);

  return (
    <div className={`chart ${spec.wide ? "wide" : ""}`}>
      <div className="chart-head">
        <span className="chart-title">{t(spec.title)}</span>
        {spec.note && <span className="muted small">{t(spec.note)}</span>}
        <span className="spacer" />
        {refs.map((r) => (
          <span key={r.path} className="ref-key small" style={{ color: REF_COLOR[r.tone] }}>
            <span className="ref-dash" style={{ borderColor: REF_COLOR[r.tone] }} />
            {t(r.label)} {num(left, r.value)}
          </span>
        ))}
      </div>
      <div className="chart-stats">
        {summaries.map(({ s, st }) => (
          <span key={s.metric.field}>
            <span className="sw" style={{ background: s.metric.color }} />
            <b>{t(s.name)}</b>
            {st ? (
              <>
                {" "}
                {t("stats.min")} <b>{num(s.metric, st.min)}</b> · {t("stats.avg")}{" "}
                <b>{num(s.metric, st.avg, s.metric.fixed ? 0 : 1)}</b> · {t("stats.max")}{" "}
                <b>{num(s.metric, st.max)}</b> <span className="muted">{s.metric.unit}</span>
              </>
            ) : (
              <span className="muted"> —</span>
            )}
          </span>
        ))}
      </div>
      {!hasData ? (
        <div className="chart-empty muted small">{t("history.noData")}</div>
      ) : (
        <ResponsiveContainer width="100%" height={170}>
          <ComposedChart data={rows} margin={{ top: 10, right: right ? 0 : 12, bottom: 0, left: 0 }}>
            <CartesianGrid stroke={chartStyle.grid} strokeDasharray="3 3" />
            <XAxis
              dataKey="t"
              type="number"
              scale="time"
              domain={[from, to]}
              ticks={timeTicks(from, to)}
              tickFormatter={(ms: number) => fmtAxisTime(ms, lang, minutes)}
              stroke={chartStyle.axis}
              fontSize={11}
              minTickGap={36}
            />
            <YAxis
              yAxisId="left"
              stroke={chartStyle.axis}
              fontSize={11}
              width={52}
              domain={domainOf(left)}
              tickFormatter={(v: number) => fmtNumber(v, lang, left.zeroBased ? left.digits : left.digits + 1)}
              label={axisUnit(left.unit)}
            />
            {right && (
              <YAxis
                yAxisId="right"
                orientation="right"
                stroke={chartStyle.axis}
                fontSize={11}
                width={52}
                domain={domainOf(right)}
                tickFormatter={(v: number) => fmtNumber(v, lang, right.digits + 1)}
                label={axisUnit(right.unit, "right")}
              />
            )}
            <Tooltip
              {...chartStyle.tooltip}
              labelFormatter={(ms) => fmtTooltipTime(Number(ms), lang, minutes)}
              formatter={(v, _name, item) => {
                const m = byKey.get(String(item.dataKey));
                if (typeof v !== "number" || !m) return "—";
                return `${m.approx ? "≈ " : ""}${num(m, v)} ${m.unit}`;
              }}
            />
            {refs.map((r) => (
              <ReferenceLine
                key={r.path}
                yAxisId="left"
                y={r.value}
                stroke={REF_COLOR[r.tone]}
                strokeDasharray="6 4"
                ifOverflow="extendDomain"
              />
            ))}
            {reboots.map((ms) => (
              <ReferenceLine
                key={ms}
                yAxisId="left"
                x={ms}
                stroke={REBOOT_COLOR}
                strokeDasharray="2 3"
                label={{ value: t("monitor.reboot"), fill: REBOOT_COLOR, fontSize: 10, position: "insideTopLeft" }}
              />
            ))}
            {spec.series.map((s) => (
              <Line
                key={s.metric.field}
                yAxisId={s.right ? "right" : "left"}
                type="monotone"
                dataKey={keyOf(s.metric.field)}
                name={t(s.name)}
                stroke={s.metric.color}
                strokeWidth={2}
                dot={false}
                connectNulls={false}
                isAnimationActive={false}
              />
            ))}
          </ComposedChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}

/** 0/1 signals as step bands, one row each, sharing the time axis (last row shows it). */
function Timeline({ spec, win }: { spec: TimelineSpec; win: Window }) {
  const { t, lang } = useT();
  const { rows, from, to, minutes } = win;
  const reboots = win.reboots.filter((r) => r >= from && r <= to);
  const hasData = spec.items.some((it) => rows.some((r) => r[keyOf(it.field)] != null));
  return (
    <div className="chart wide">
      <div className="chart-head">
        <span className="chart-title">{t(spec.title)}</span>
        {spec.note && <span className="muted small">{t(spec.note)}</span>}
      </div>
      {!hasData ? (
        <div className="chart-empty muted small">{t("history.noData")}</div>
      ) : (
        <div className="timeline">
          {spec.items.map((it, i) => {
            const last = i === spec.items.length - 1;
            return (
              <div className="tl-row" key={it.field}>
                <span className="tl-label small">
                  <span className="sw" style={{ background: it.color }} />
                  {t(it.label)}
                </span>
                <ResponsiveContainer width="100%" height={last ? 46 : 24}>
                  <AreaChart data={rows} margin={{ top: 2, right: 12, bottom: 0, left: 0 }}>
                    <XAxis
                      dataKey="t"
                      type="number"
                      scale="time"
                      domain={[from, to]}
                      ticks={timeTicks(from, to)}
                      tickFormatter={(ms: number) => fmtAxisTime(ms, lang, minutes)}
                      stroke={chartStyle.axis}
                      fontSize={11}
                      minTickGap={36}
                      hide={!last}
                    />
                    <YAxis hide domain={[0, 1]} />
                    <Tooltip
                      {...chartStyle.tooltip}
                      labelFormatter={(ms) => fmtTooltipTime(Number(ms), lang, minutes)}
                      formatter={(v) => (typeof v !== "number" ? "—" : v ? t("common.yes") : t("common.no"))}
                    />
                    {reboots.map((ms) => (
                      <ReferenceLine key={ms} x={ms} stroke={REBOOT_COLOR} strokeDasharray="2 3" />
                    ))}
                    <Area
                      type="stepAfter"
                      dataKey={keyOf(it.field)}
                      name={t(it.label)}
                      stroke={it.color}
                      fill={it.color}
                      fillOpacity={0.45}
                      connectNulls={false}
                      isAnimationActive={false}
                    />
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

/** Detail charts of one node over the selected window (rows from NodeMonitor). */
export function NodeHistoryCharts({
  node,
  win,
  showPresence = true,
}: {
  node: NodeOut;
  win: Window;
  /** false for dispatchers: no presence timeline */
  showPresence?: boolean;
}) {
  const water = node.kind === "water";
  const charts = water ? WATER_CHARTS : AIR_CHARTS;
  const timeline = water ? WATER_TIMELINE : AIR_TIMELINE;
  return (
    <div className="charts">
      {charts.map((spec) => (
        <MetricChart key={spec.id} spec={spec} doc={node.status} win={win} />
      ))}
      {(water || showPresence) && <Timeline spec={timeline} win={win} />}
    </div>
  );
}
