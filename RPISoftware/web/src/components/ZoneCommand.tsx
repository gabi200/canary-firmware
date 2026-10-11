/**
 * Zone command view: a wide control-room panel for one zone (replaces the old side drawer).
 * Hero header in the zone's status colour with the ISO 7010 hazard sign, big stat tiles and a
 * clickable mini-map of the building; tabs for overview (why here, analysis, actions, verdict),
 * live sensors, people, evacuation and the incident timeline.
 * Modal: Esc closes, focus stays inside, returns to the map; deep link ?zone=&sensor=.
 */
import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { Area, AreaChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";

import { useIncidentEvents, useNodeHistories } from "../api/hooks";
import type { Evacuation, Incident, Resident, Roster, Triangulation, ZoneSummary } from "../api/types";
import { pluralCategory, useT, type Lang, type TFn } from "../i18n";
import { fmtNumber, fmtReading } from "../lib/format";
import {
  MAP_FIELDS,
  type ChannelState,
  type ContributorView,
  type Layout,
  type MapSensor,
  type SourceView,
  type ZoneView,
  zoneStatusText,
} from "../lib/hazardMap";
import {
  kindLabel,
  levelLabel,
  prettyId,
  sensorLabel,
  stateLabel,
  tokenLabel,
  triangulationMethodLabel,
  zoneKindLabel,
  zoneLabel,
} from "../lib/labels";
import { LEVEL_COLOR, keyOf, toRows, type Level, type Row } from "../lib/metrics";
import { pick } from "../lib/nodes";
import { fmtAgo, fmtClock, fmtDuration, fmtTooltipTime, parseTs } from "../lib/time";
import { NodeAnalysisView } from "./Analysis";
import {
  CloseIcon,
  LockIcon,
  RouteIcon,
  TrendDownIcon,
  TrendFlatIcon,
  TrendUpIcon,
  WarningIcon,
} from "./Icons";
import { IncidentTimeline } from "./IncidentTimeline";
import { KIND_ICON } from "./ScopeBar";
import { NodeCommands } from "./NodeCommands";
import { PersonCard } from "./PriorityPanel";
import { SafetySign, hazardAdviceSigns, hazardSign, signName, type SignCode } from "./SafetySigns";
import { SignalBadge } from "./SignalBadge";
import { SignatureBadge } from "./SignatureBadge";
import { chartStyle } from "./TrendChart";

export interface CommandContext {
  incident: Incident | null;
  /** minutes of history covering the incident (or 30 without one) */
  windowMinutes: number;
  triangulation?: Triangulation;
  contributors: ContributorView[];
  zoneNames: Map<string, string>;
  roster?: Roster;
  residents?: Resident[];
  evacuation?: Evacuation;
  summaryZone?: ZoneSummary;
  /** live map model for the mini-map */
  layout: Layout;
  zones: ZoneView[];
  source: SourceView | null;
}

const HAZARD_OF_FIELD: Record<string, string> = {
  "co.ppm": "co",
  "gas.adc": "combustible_gas",
  "particulate.pm2_5": "particulate",
  "particulate.pm10": "particulate",
  "sensor.adc": "water_leak",
};
const OPEN_ALARM = new Set(["alarm", "escalation", "evacuation"]);
const TREND_ICON = { rising: TrendUpIcon, falling: TrendDownIcon, stable: TrendFlatIcon };
type Tab = "overview" | "sensors" | "people" | "evacuation" | "timeline";
const TABS: { id: Tab; label: Parameters<TFn>[0] }[] = [
  { id: "overview", label: "cmd.tabOverview" },
  { id: "sensors", label: "cmd.tabSensors" },
  { id: "people", label: "cmd.tabPeople" },
  { id: "evacuation", label: "cmd.tabEvacuation" },
  { id: "timeline", label: "cmd.tabTimeline" },
];

const pctText = (v: number, lang: Lang) => `${fmtNumber(Math.round(v * 100), lang, 0)}%`;

/** Backend analysis of the zone's nodes (headline, indicators, advice). */
function Analysis({ summaryZone }: { summaryZone?: ZoneSummary }) {
  const { t } = useT();
  const nodes = summaryZone?.nodes ?? [];
  if (nodes.length === 0) return <p className="muted small">{t("node.noAnalysis")}</p>;
  return (
    <div className="cmd-analysis">
      {nodes.map((n) => (
        <div key={n.node_id} className="zone-node">
          <div className="zone-node-name">
            {n.name} <span className="tag">{kindLabel(n.kind, t)}</span>
          </div>
          <NodeAnalysisView analysis={n} />
        </div>
      ))}
    </div>
  );
}

/** "Etaj 3" from the backend, else from the id ("flr_03" -> "Floor 3"). */
function floorText(zone: ZoneView, ctx: CommandContext, t: TFn): string {
  const z = zone.placed.zone;
  const fromPeople = ctx.roster?.priority?.find((p) => p.unit_id === z.unit_id)?.floor_label;
  if (z.floor_label || fromPeople) return (z.floor_label || fromPeople)!;
  const n = /(\d+)$/.exec(z.floor_id)?.[1];
  return t("drawer.floor", { n: n ? String(Number(n)) : prettyId(z.floor_id) });
}

function unitText(zone: ZoneView, ctx: CommandContext, t: TFn): string {
  const z = zone.placed.zone;
  return (
    z.unit_label ||
    ctx.roster?.priority?.find((p) => p.unit_id === z.unit_id)?.unit_label ||
    ctx.roster?.entries.find((e) => e.unit_id === z.unit_id)?.unit_label ||
    ctx.residents?.find((r) => r.unit_id === z.unit_id)?.unit_label ||
    t("drawer.unit", { n: prettyId(z.unit_id) })
  );
}

function trendOf(rows: Row[], key: string, scale: number | null, now: number): "rising" | "falling" | "stable" | null {
  const recent = rows.filter((r) => (r.t as number) >= now - 10 * 60_000 && r[key] != null);
  if (recent.length < 4) return null;
  const k = Math.min(3, Math.floor(recent.length / 2));
  const avg = (rs: Row[]) => rs.reduce((s, r) => s + (r[key] as number), 0) / rs.length;
  const d = (avg(recent.slice(-k)) - avg(recent.slice(0, k))) / (scale || Math.max(Math.abs(avg(recent.slice(0, k))), 1));
  return d > 0.03 ? "rising" : d < -0.03 ? "falling" : "stable";
}

interface Crossing {
  sensor: MapSensor;
  channel: ChannelState;
  t: number;
}

/** First time each channel reached its lower threshold since the incident opened. */
function crossings(sensors: MapSensor[], rowsOf: Map<string, Row[]>, opened: number | null): Crossing[] {
  if (opened == null) return [];
  const out: Crossing[] = [];
  for (const s of sensors) {
    const rows = rowsOf.get(s.id);
    if (!rows) continue;
    for (const c of s.channels) {
      if (c.warn == null) continue;
      const key = keyOf(c.metric.field);
      const hit = rows.find((r) => (r.t as number) >= opened && r[key] != null && (r[key] as number) >= c.warn!);
      if (hit) out.push({ sensor: s, channel: c, t: hit.t as number });
    }
  }
  return out.sort((a, b) => a.t - b.t);
}

// --------------------------------------------------------------------------- //
// visuals
// --------------------------------------------------------------------------- //

/** Ring gauge: "arc" = 3/4 dial (share of a threshold), "donut" = full ring (confidence). */
function Gauge({ value, color, center, variant }: { value: number | null; color: string; center: ReactNode; variant: "arc" | "donut" }) {
  const size = 92;
  const stroke = 10;
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const span = variant === "arc" ? 0.75 : 1;
  const v = Math.max(0, Math.min(1, value ?? 0));
  const rot = variant === "arc" ? 135 : -90;
  return (
    <div className="gauge">
      <svg viewBox={`0 0 ${size} ${size}`} width={size} height={size} aria-hidden="true">
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke="#2c3846"
          strokeWidth={stroke}
          strokeDasharray={`${c * span} ${c}`}
          strokeLinecap="round"
          transform={`rotate(${rot} ${size / 2} ${size / 2})`}
        />
        {value != null && (
          <circle
            cx={size / 2}
            cy={size / 2}
            r={r}
            fill="none"
            stroke={color}
            strokeWidth={stroke}
            strokeDasharray={`${c * span * v} ${c}`}
            strokeLinecap="round"
            transform={`rotate(${rot} ${size / 2} ${size / 2})`}
          />
        )}
      </svg>
      <div className="gauge-center">{center}</div>
    </div>
  );
}

function StatTile({ label, children, sub, tone }: { label: string; children: ReactNode; sub?: ReactNode; tone?: Level | "priority" }) {
  return (
    <div className={`cmd-stat ${tone ? `tone-${tone}` : ""}`}>
      <div className="cmd-stat-label">{label}</div>
      <div className="cmd-stat-body">{children}</div>
      {sub && <div className="cmd-stat-sub">{sub}</div>}
    </div>
  );
}

function ThresholdBar({ c }: { c: ChannelState }) {
  if (c.value == null || c.danger == null) return null;
  const max = Math.max(c.danger * 1.15, c.value * 1.05, (c.warn ?? 0) * 1.3, 1);
  const pos = (v: number) => `${Math.min(100, (v / max) * 100)}%`;
  return (
    <div className="tbar big" aria-hidden="true">
      <div className="tbar-fill" style={{ width: pos(c.value), background: LEVEL_COLOR[c.level] }} />
      {c.warn != null && <div className="tbar-tick warn" style={{ left: pos(c.warn) }} />}
      <div className="tbar-tick danger" style={{ left: pos(c.danger) }} />
    </div>
  );
}

/** Small area chart of one channel with the device's thresholds as dashed lines. */
function ChannelChart({ c, rows, from, to }: { c: ChannelState; rows: Row[]; from: number; to: number }) {
  const { lang } = useT();
  const key = keyOf(c.metric.field);
  const data = rows.filter((r) => (r.t as number) >= from);
  if (!data.some((r) => r[key] != null)) return <div className="cmd-chart-empty muted small">—</div>;
  const minutes = (to - from) / 60_000;
  return (
    <ResponsiveContainer width="100%" height={92}>
      <AreaChart data={data} margin={{ top: 6, right: 4, bottom: 0, left: 4 }}>
        <XAxis dataKey="t" type="number" domain={[from, to]} hide />
        <YAxis hide domain={c.metric.zeroBased ? [0, "auto"] : [`dataMin - ${c.metric.pad ?? 1}`, `dataMax + ${c.metric.pad ?? 1}`]} />
        <Tooltip
          {...chartStyle.tooltip}
          labelFormatter={(ms) => fmtTooltipTime(Number(ms), lang, minutes)}
          formatter={(v) => (typeof v === "number" ? `${fmtNumber(v, lang, c.metric.digits, c.metric.fixed)} ${c.metric.unit}` : "—")}
        />
        {c.warn != null && <ReferenceLine y={c.warn} stroke="#d29922" strokeDasharray="5 4" ifOverflow="extendDomain" />}
        {c.danger != null && <ReferenceLine y={c.danger} stroke="#f85149" strokeDasharray="5 4" ifOverflow="extendDomain" />}
        <Area
          type="monotone"
          dataKey={key}
          stroke={c.level === "danger" ? "#f85149" : c.level === "attention" ? "#d29922" : c.metric.color}
          fill={c.level === "danger" ? "#f85149" : c.level === "attention" ? "#d29922" : c.metric.color}
          fillOpacity={0.18}
          strokeWidth={2}
          dot={false}
          connectNulls={false}
          isAnimationActive={false}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}

/** Whole building, small (the plan's schematic, compact): apartment blocks with their room tiles
 *  as kind icons; click a room to switch the command view to it. */
function MiniMap({ ctx, selectedId, onSelect }: { ctx: CommandContext; selectedId: string; onSelect: (id: string) => void }) {
  const { t } = useT();
  const { layout, zones, source, contributors } = ctx;
  const clip = `mm-${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const unitOf = new Map<string, string>();
  for (const u of layout.units) for (const id of u.zoneIds) unitOf.set(id, u.label);
  return (
    <svg className="minimap" viewBox={`0 0 ${layout.width} ${layout.height}`} role="group" aria-label={t("cmd.miniMap")}>
      <defs>
        <clipPath id={clip}>
          <rect x={0} y={0} width={layout.width} height={layout.height} />
        </clipPath>
      </defs>
      {layout.units.map((u) => {
        const max = Math.max(3, Math.floor((u.w - 20) / 13));
        return (
          <g key={`u-${u.id}`} aria-hidden="true">
            <rect
              x={u.x}
              y={u.y}
              width={u.w}
              height={u.h}
              rx={10}
              fill={u.common ? "#141a21" : "#121922"}
              stroke="#35424f"
              strokeWidth={2}
              strokeDasharray={u.common ? "8 6" : undefined}
            />
            <text className="fp-text" x={u.x + 10} y={u.y + 25} fill="#e6edf3" fontSize={22} fontWeight={800}>
              {u.label.length > max ? `${u.label.slice(0, max - 1)}…` : u.label}
            </text>
          </g>
        );
      })}
      {zones.map((z) => (
        <rect
          key={`f-${z.placed.zone.id}`}
          x={z.placed.x}
          y={z.placed.y}
          width={z.placed.w}
          height={z.placed.h}
          rx={8}
          fill={z.level === "unknown" || z.level === "none" ? "#222c38" : LEVEL_COLOR[z.level]}
          fillOpacity={z.level === "unknown" || z.level === "none" ? 1 : 0.35}
        />
      ))}
      {source && (
        <g clipPath={`url(#${clip})`} pointerEvents="none">
          <circle cx={source.x} cy={source.y} r={source.r} fill="#f85149" fillOpacity={0.16} stroke="#f85149" strokeDasharray="6 6" strokeWidth={2} />
          {contributors.map((c) => (
            <line key={c.deviceId} x1={c.x} y1={c.y} x2={source.x} y2={source.y} stroke="#fff" strokeOpacity={0.35 + 0.6 * c.weight} strokeWidth={2 + 4 * c.weight} />
          ))}
          {contributors.map((c) => (
            <circle key={`d-${c.deviceId}`} cx={c.x} cy={c.y} r={6 + 3 * c.weight} fill="#f85149" stroke="#fff" strokeWidth={2.5} />
          ))}
          <circle cx={source.x} cy={source.y} r={8} fill="#fff" stroke="#f85149" strokeWidth={3.5} />
        </g>
      )}
      {zones.map((z) => {
        const { x, y, w, h, zone } = z.placed;
        const sel = zone.id === selectedId;
        const name = zone.label || prettyId(zone.id);
        const unit = unitOf.get(zone.id);
        const label = unit ? `${name} · ${unit}` : name;
        const KindIcon = KIND_ICON[zone.kind] as (typeof KIND_ICON)[string] | undefined;
        const act = () => onSelect(zone.id);
        return (
          <g
            key={zone.id}
            className="fp-btn"
            role="button"
            tabIndex={0}
            aria-label={label}
            aria-current={sel ? "true" : undefined}
            onClick={act}
            onKeyDown={(e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                act();
              }
            }}
          >
            <title>{label}</title>
            <rect x={x} y={y} width={w} height={h} rx={8} fill="transparent" stroke={sel ? "#ffffff" : "#2c3846"} strokeWidth={sel ? 6 : 2} />
            {KindIcon ? (
              <KindIcon x={x + w / 2 - 13} y={y + h / 2 - 13} width={26} height={26} style={{ color: "#e6edf3", pointerEvents: "none" }} />
            ) : (
              <text className="fp-text" x={x + w / 2} y={y + h / 2 + 7} textAnchor="middle" fill="#e6edf3" fontSize={20} fontWeight={800} pointerEvents="none">
                {name.slice(0, 3)}
              </text>
            )}
            <rect className="fp-ring" x={x - 5} y={y - 5} width={w + 10} height={h + 10} rx={12} />
          </g>
        );
      })}
    </svg>
  );
}

// --------------------------------------------------------------------------- //
// sections
// --------------------------------------------------------------------------- //

function WhyHere({ zone, ctx }: { zone: ZoneView; ctx: CommandContext }) {
  const { t, lang } = useT();
  const tri = ctx.triangulation;
  if (!tri || !tri.source_zone_id) return <p className="muted">{t("dispatch.awaitingSensors")}</p>;
  const id = zone.placed.zone.id;
  const list = [...(tri.contributors ?? [])].sort((a, b) => b.weight - a.weight);
  const top = list[0];
  const share = list.filter((c) => c.zone_id === id).reduce((s, c) => s + c.weight, 0);
  const view = (deviceId: string) => ctx.contributors.find((c) => c.deviceId === deviceId);
  const n = tri.n_contributors;
  return (
    <>
      <p className="cmd-lead">
        {t(`why.basis.${pluralCategory(lang, n)}`, { n })}{" "}
        {zone.isSource ? t("why.isSource") : t("why.notSource", { zone: zoneLabel(ctx.zoneNames, tri.source_zone_id) })}{" "}
        {top && top.zone_id === id
          ? t("why.topHere", { sensor: view(top.device_id)?.name ?? top.device_id, pct: pctText(top.weight, lang) })
          : share > 0
            ? t("why.shareHere", { pct: pctText(share, lang) })
            : t("why.notContributing")}
      </p>
      <div className="small muted">{t("cmd.contributors")}</div>
      <div className="wbars">
        {list.map((c) => {
          const v = view(c.device_id);
          return (
            <div key={c.device_id} className={`wbar ${c.zone_id === id ? "here" : ""}`}>
              <div className="wbar-label">
                <b>{v?.name ?? c.device_id}</b>
                <span className="muted"> · {zoneLabel(ctx.zoneNames, c.zone_id)}</span>
              </div>
              <div className="wbar-track">
                <div className="wbar-fill" style={{ width: `${Math.max(2, c.weight * 100)}%` }} />
              </div>
              <div className="wbar-value">
                <b>{pctText(c.weight, lang)}</b>
                <span className="muted">
                  {" "}
                  · {fmtNumber(c.value, lang, v?.digits ?? 1)} {v?.unit ?? ""}
                </span>
              </div>
            </div>
          );
        })}
      </div>
      <p className="small" style={{ marginTop: 10 }}>
        <span className="muted">{t("why.method")}:</span> {triangulationMethodLabel(tri.method, t)}
        <br />
        <span className="muted">{tri.airflow_applied ? t("why.airflow") : t("why.noAirflow")}</span>
      </p>
      <p className="muted small">{t("dispatch.estimateNote")}</p>
    </>
  );
}

function hazardOf(zone: ZoneView, incident: Incident | null, sensors: MapSensor[]): string | null {
  if (incident && (zone.isSource || zone.isAffected)) return incident.hazard_type;
  const worst = sensors
    .flatMap((s) => s.channels)
    .filter((c) => c.level === "danger" || c.level === "attention")
    .sort((a, b) => (b.ratio ?? 0) - (a.ratio ?? 0))[0];
  return worst ? HAZARD_OF_FIELD[worst.metric.field] ?? null : null;
}

function ActionsBody({ zone, incident, sensors, t, lang, advice }: { zone: ZoneView; incident: Incident | null; sensors: MapSensor[]; t: TFn; lang: Lang; advice?: string[] }) {
  const hazard = hazardOf(zone, incident, sensors);
  const signs: SignCode[] = hazard ? [hazardSign(hazard), ...hazardAdviceSigns(hazard)] : [];
  return (
    <>
      {(advice ?? []).length === 0 && signs.length === 0 && <p className="muted small">{t("drawer.noAdvice")}</p>}
      {(advice ?? []).length > 0 && (
        <ul className="advice">
          {advice!.map((a, i) => (
            <li key={i}>{a}</li>
          ))}
        </ul>
      )}
      {signs.length > 0 && (
        <div className="drawer-signs">
          {signs.map((code) => (
            <span key={code} className="sign-chip">
              <SafetySign code={code} size={44} className="safety-sign" />
              <span className="small">{signName(code, lang)}</span>
            </span>
          ))}
        </div>
      )}
    </>
  );
}

function SensorCard({
  s,
  rows,
  from,
  to,
  incident,
  highlight,
}: {
  s: MapSensor;
  rows: Row[] | undefined;
  from: number;
  to: number;
  incident: Incident | null;
  highlight: boolean;
}) {
  const { t, lang } = useT();
  const opened = incident ? parseTs(incident.opened_ts) : null;
  if (!s.node) {
    const r = s.reading;
    return (
      <section id={`sensor-${s.id}`} className={`cmd-sensor ${highlight ? "highlight" : ""}`}>
        <div className="ds-head">
          <b>{s.name}</b>
          <span className="tag">{sensorLabel(s.device?.sensor_type ?? "", t)}</span>
          {s.hazard && <span className={`pill ${s.level}`}>{levelLabel(s.level, t)}</span>}
          <span className="spacer" />
          {s.lastTs && <span className="muted small">{t("map.updated", { ago: fmtAgo(s.lastTs, lang) })}</span>}
        </div>
        <div className={`cmd-big t-${s.level}`}>{r ? fmtReading(r.value, r.units, lang, t) : "—"}</div>
        <div className="muted small">{t("drawer.legacy")}</div>
      </section>
    );
  }
  return (
    <section id={`sensor-${s.id}`} className={`cmd-sensor ${highlight ? "highlight" : ""}`}>
      <div className="ds-head">
        <b>{s.name}</b>
        <span className="tag">{kindLabel(s.node.kind, t)}</span>
        <span className={`pill ${s.online ? "ok" : "attention"}`}>{t(s.online ? "conn.online" : "conn.offline")}</span>
        <span className="spacer" />
        {s.lastTs && <span className="muted small">{t("map.updated", { ago: fmtAgo(s.lastTs, lang) })}</span>}
      </div>
      {/* hardware test: silence / valve from the control room (managers / admins only) */}
      <NodeCommands node={s.node} variant="compact" />
      {s.channels.map((c) => {
        const m = c.metric;
        const key = keyOf(m.field);
        const trend = rows ? trendOf(rows, key, c.danger, to) : null;
        const TrendIcon = trend ? TREND_ICON[trend] : null;
        const num = (v: number) => fmtNumber(v, lang, m.digits, m.fixed);
        const dry = m.refs?.[0].label === "threshold.dry";
        const first =
          rows && opened != null && c.warn != null
            ? rows.find((r) => (r.t as number) >= opened && r[key] != null && (r[key] as number) >= c.warn!)
            : undefined;
        return (
          <div key={m.field} className="cmd-channel">
            <div className="cmd-channel-head">
              <span className="ch-label">{t(m.label)}</span>
              {TrendIcon && trend && (
                <span className="ch-trend" title={tokenLabel(t, "trend", trend)}>
                  <TrendIcon />
                  <span className="sr-only">{tokenLabel(t, "trend", trend)}</span>
                </span>
              )}
              <span className={`cmd-value t-${c.level}`}>
                {c.value == null ? (c.trust === "ok" ? "—" : t(`tile.${c.trust}`)) : num(c.value)}
                {c.value != null && <span className="cmd-unit">{m.unit}</span>}
              </span>
            </div>
            <ThresholdBar c={c} />
            {c.warn != null && c.danger != null && m.refs && (
              <div className="ch-refs small">
                <span className="t-attention">{t(m.refs[0].label)} {num(c.warn)}</span>
                {" · "}
                <span className="t-danger">{t(m.refs[1].label)} {num(c.danger)}</span>
                {c.ratio != null && <span className="muted"> · {t("map.ofDanger", { pct: pctText(c.ratio, lang) })}</span>}
              </div>
            )}
            {rows && <ChannelChart c={c} rows={rows} from={from} to={to} />}
            {incident && c.warn != null && (
              <div className="small ch-first">
                {first ? (
                  <span className="t-attention">
                    <WarningIcon />{" "}
                    {t(dry ? "drawer.firstDry" : "drawer.firstWarn", { time: fmtClock(first.t as number, lang) })}
                  </span>
                ) : (
                  <span className="muted">{t(dry ? "drawer.neverDry" : "drawer.neverWarn")}</span>
                )}
              </div>
            )}
          </div>
        );
      })}
    </section>
  );
}

// --------------------------------------------------------------------------- //
// the view
// --------------------------------------------------------------------------- //

export function ZoneCommand({
  zone,
  ctx,
  focusSensorId,
  onClose,
  onSelectZone,
}: {
  zone: ZoneView;
  ctx: CommandContext;
  focusSensorId: string | null;
  onClose: () => void;
  onSelectZone: (zoneId: string) => void;
}) {
  const { t, lang } = useT();
  const titleId = useId();
  const panel = useRef<HTMLDivElement>(null);
  const closeBtn = useRef<HTMLButtonElement>(null);
  const [tab, setTab] = useState<Tab>(focusSensorId ? "sensors" : "overview");
  const [span, setSpan] = useState<30 | 120>(30);
  const [closing, setClosing] = useState(false);
  const z = zone.placed.zone;
  // switching zone from the mini-map keeps the panel (and its focus return) but resets the tab
  useEffect(() => {
    if (!focusSensorId) setTab("overview");
  }, [z.id]); // eslint-free: focusSensorId is read once per zone switch
  const incident = ctx.incident;
  const involved = !!incident && (zone.isSource || zone.isAffected);
  const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  const requestClose = () => {
    if (reduced) onClose();
    else {
      setClosing(true);
      window.setTimeout(onClose, 150);
    }
  };

  // focus in on open, back to the opener on close
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null;
    closeBtn.current?.focus();
    return () => opener?.focus?.();
  }, []);

  // a sensor deep link opens the sensors tab scrolled to it
  useEffect(() => {
    if (!focusSensorId) return;
    setTab("sensors");
    const id = window.setTimeout(() => {
      document.getElementById(`sensor-${focusSensorId}`)?.scrollIntoView({ block: "start", behavior: reduced ? "auto" : "smooth" });
    }, 60);
    return () => window.clearTimeout(id);
  }, [focusSensorId, z.id, reduced]);

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === "Escape") {
      e.stopPropagation();
      requestClose();
      return;
    }
    if (e.key !== "Tab" || !panel.current) return;
    const items = panel.current.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"]), summary',
    );
    if (items.length === 0) return;
    const first = items[0];
    const last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };
  const onTabKey = (e: KeyboardEvent, i: number) => {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    e.preventDefault();
    const next = TABS[(i + (e.key === "ArrowRight" ? 1 : TABS.length - 1)) % TABS.length];
    setTab(next.id);
    document.getElementById(`${titleId}-tab-${next.id}`)?.focus();
  };

  // history of the zone's nodes: since the incident opened (crossings) and the chart span
  const nodes = zone.sensors.filter((s) => s.node);
  const others = zone.sensors.filter((s) => !s.node);
  const minutes = Math.max(ctx.windowMinutes, span);
  const histories = useNodeHistories(
    nodes.map((s) => ({ nodeId: s.id, fields: MAP_FIELDS[s.node!.kind] ?? [] })),
    minutes,
    60_000,
  );
  const stamp = histories.map((h) => h.dataUpdatedAt).join(",");
  const rowsOf = useMemo(() => {
    const m = new Map<string, Row[]>();
    histories.forEach((h, i) => {
      const s = nodes[i];
      if (h.data && s) m.set(s.id, toRows(h.data.points ?? [], MAP_FIELDS[s.node!.kind] ?? [], s.node!.kind));
    });
    return m;
  }, [stamp, nodes.map((s) => s.id).join(",")]); // histories / nodes are new arrays each render
  const now = Math.max(Date.now(), ...histories.map((h) => h.dataUpdatedAt || 0));
  const opened = incident ? parseTs(incident.opened_ts) : null;
  const cross = crossings(nodes, rowsOf, opened);
  const events = useIncidentEvents(incident?.id ?? null);

  // stats
  const worst = nodes
    .flatMap((s) => s.channels)
    .filter((c) => c.ratio != null)
    .sort((a, b) => (b.ratio ?? 0) - (a.ratio ?? 0))[0];
  const tri = ctx.triangulation;
  const unitId = z.unit_id;
  const priority = incident ? (ctx.roster?.priority ?? []).filter((p) => p.unit_id === unitId) : [];
  const priorityWaiting = priority.filter((p) => p.status !== "safe_outside" && p.status !== "safe_inside").length;
  const presence = nodes
    .map((s) => pick(s.node!.status, "presence.detected"))
    .find((v) => typeof v === "boolean") as boolean | undefined;
  const hazard = hazardOf(zone, incident, nodes);
  const tone: Level = involved
    ? OPEN_ALARM.has(incident!.state)
      ? "danger"
      : "attention"
    : zone.level === "none"
      ? "unknown"
      : zone.level;
  const advice = Array.from(new Set((ctx.summaryZone?.nodes ?? []).flatMap((n) => n.advice ?? [])));
  const residents = incident
    ? (ctx.roster?.entries ?? []).filter((e) => e.unit_id === unitId)
    : (ctx.residents ?? []).filter((r) => r.unit_id === unitId).map((r) => ({ ...r, status: "", ts: null }));
  const routes = ctx.evacuation?.routes ?? [];
  const dangerous = zone.isSource || zone.isAffected || zone.level === "danger";
  const statusText = zoneStatusText(zone, t);

  const verdict = involved && (
    <section className="cmd-card">
      <h3>{t("drawer.verdict")}</h3>
      {incident!.false_alarm_class || incident!.signature ? (
        <>
          <div>
            <SignalBadge cls={incident!.false_alarm_class} />
            <SignatureBadge signature={incident!.signature} />
          </div>
          {incident!.benign_score != null && <p className="small">{t("drawer.benign", { pct: pctText(incident!.benign_score, lang) })}</p>}
          {(incident!.signature?.evidence ?? []).length > 0 && (
            <>
              <div className="small muted">{t("drawer.evidence")}</div>
              <ul className="evidence">
                {incident!.signature!.evidence.map((e, i) => (
                  <li key={i}>{e}</li>
                ))}
              </ul>
            </>
          )}
        </>
      ) : (
        <p className="muted small">{t("drawer.noVerdict")}</p>
      )}
    </section>
  );

  return (
    <>
      <div className={`cmd-backdrop ${closing ? "closing" : ""}`} onClick={requestClose} />
      <div
        ref={panel}
        className={`cmd ${closing ? "closing" : ""}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onKeyDown={onKeyDown}
      >
        <header className={`cmd-hero tone-${tone}`}>
          <div className="cmd-hero-main">
            {hazard && <SafetySign code={hazardSign(hazard)} size={84} className="safety-sign cmd-sign" />}
            <div className="cmd-title">
              <h2 id={titleId}>{z.label || z.id}</h2>
              <div className="cmd-sub">
                {zoneKindLabel(z.kind, t)} · {unitText(zone, ctx, t)} · {floorText(zone, ctx, t)}
              </div>
              <div className="cmd-badges">
                {incident && (
                  <span className={`pill ${OPEN_ALARM.has(incident.state) ? "alarm" : "detection"}`}>
                    {t("cmd.incidentState", { state: stateLabel(incident.state, t) })}
                  </span>
                )}
                <span className={`pill ${zone.level === "unknown" || statusText === t("cmd.readingsNormal") ? "outline" : zone.level}`}>
                  {t("cmd.zoneStatus", { status: statusText })}
                </span>
                {zone.isSource && <span className="pill alarm">{t("map.sourceBadge")}</span>}
              </div>
            </div>
          </div>
          <div className="cmd-hero-map">
            <MiniMap ctx={ctx} selectedId={z.id} onSelect={onSelectZone} />
          </div>
          <button ref={closeBtn} type="button" className="btn icon-btn cmd-close" onClick={requestClose} aria-label={t("drawer.close")}>
            <CloseIcon />
          </button>
        </header>

        <div className="cmd-stats">
          <StatTile
            label={t("cmd.statWorst")}
            tone={worst?.level ?? "unknown"}
            sub={worst ? `${t(worst.metric.label)} · ${fmtNumber(worst.value!, lang, worst.metric.digits, worst.metric.fixed)} ${worst.metric.unit}` : t("map.noData")}
          >
            <Gauge
              variant="arc"
              value={worst?.ratio ?? null}
              color={worst ? LEVEL_COLOR[worst.level] : "#8b98a8"}
              center={<b>{worst ? pctText(worst.ratio!, lang) : "—"}</b>}
            />
            <span className="cmd-stat-caption">{t("cmd.ofDanger")}</span>
          </StatTile>
          <StatTile
            label={t("cmd.statConfidence")}
            sub={
              incident && tri?.source_zone_id
                ? t(`why.basis.${pluralCategory(lang, tri.n_contributors)}`, { n: tri.n_contributors })
                : incident
                  ? t("cmd.noEstimate")
                  : t("cmd.onlyDuringIncident")
            }
          >
            <Gauge
              variant="donut"
              value={incident && tri?.source_zone_id ? tri.confidence : null}
              color="#58a6ff"
              center={<b>{incident && tri?.source_zone_id ? pctText(tri.confidence, lang) : "—"}</b>}
            />
          </StatTile>
          <StatTile
            label={t("cmd.statPeople")}
            sub={presence == null ? undefined : presence ? t("drawer.presenceYes") : t("drawer.presenceNo")}
          >
            <span className="cmd-stat-number">{fmtNumber(Math.round(zone.occupancy), lang, 0)}</span>
          </StatTile>
          <StatTile
            label={t("cmd.statPriority")}
            tone={priorityWaiting > 0 ? "priority" : undefined}
            sub={incident ? unitText(zone, ctx, t) : t("cmd.onlyDuringIncident")}
          >
            <span className="cmd-stat-number">{incident ? fmtNumber(priorityWaiting, lang, 0) : "—"}</span>
          </StatTile>
          <StatTile
            label={t("cmd.statCrossing")}
            tone={cross.length ? "attention" : undefined}
            sub={
              cross.length
                ? `${t(cross[0].channel.metric.label)} · ${fmtClock(cross[0].t, lang)}`
                : incident
                  ? t("cmd.never")
                  : t("cmd.onlyDuringIncident")
            }
          >
            <span className="cmd-stat-number small-num">{cross.length ? fmtDuration(now - cross[0].t, lang) : "—"}</span>
          </StatTile>
        </div>

        <div className="cmd-tabs" role="tablist" aria-label={z.label || z.id}>
          {TABS.map((tb, i) => (
            <button
              key={tb.id}
              id={`${titleId}-tab-${tb.id}`}
              type="button"
              role="tab"
              aria-selected={tab === tb.id}
              aria-controls={`${titleId}-panel`}
              tabIndex={tab === tb.id ? 0 : -1}
              className={tab === tb.id ? "active" : ""}
              onClick={() => setTab(tb.id)}
              onKeyDown={(e) => onTabKey(e, i)}
            >
              {t(tb.label)}
            </button>
          ))}
        </div>

        <div className="cmd-body" id={`${titleId}-panel`} role="tabpanel" aria-labelledby={`${titleId}-tab-${tab}`}>
          {tab === "overview" && (
            <div className="cmd-grid">
              <div className="cmd-col">
                <section className="cmd-card">
                  <h3>{incident ? t("drawer.why") : t("cmd.analysis")}</h3>
                  {incident ? <WhyHere zone={zone} ctx={ctx} /> : <Analysis summaryZone={ctx.summaryZone} />}
                </section>
                {incident && (
                  <section className="cmd-card">
                    <h3>{t("cmd.analysis")}</h3>
                    <Analysis summaryZone={ctx.summaryZone} />
                  </section>
                )}
              </div>
              <div className="cmd-col">
                <section className="cmd-card">
                  <h3>{t("drawer.actions")}</h3>
                  <ActionsBody zone={zone} incident={incident} sensors={nodes} t={t} lang={lang} advice={advice} />
                </section>
                {verdict}
              </div>
            </div>
          )}

          {tab === "sensors" && (
            <>
              <div className="cmd-toolbar">
                <span className="panel-label">{t("drawer.sensors")}</span>
                <div className="seg" role="group" aria-label={t("history.range")}>
                  {([30, 120] as const).map((m) => (
                    <button key={m} type="button" className={span === m ? "active" : ""} aria-pressed={span === m} onClick={() => setSpan(m)}>
                      {t(m === 30 ? "cmd.span30" : "cmd.span2h")}
                    </button>
                  ))}
                </div>
              </div>
              {zone.sensors.length === 0 && <p className="muted">{t("drawer.noSensors")}</p>}
              <div className="cmd-sensors">
                {nodes.map((s) => (
                  <SensorCard key={s.id} s={s} rows={rowsOf.get(s.id)} from={now - span * 60_000} to={now} incident={incident} highlight={s.id === focusSensorId} />
                ))}
                {others.map((s) => (
                  <SensorCard key={s.id} s={s} rows={undefined} from={now - span * 60_000} to={now} incident={incident} highlight={s.id === focusSensorId} />
                ))}
              </div>
            </>
          )}

          {tab === "people" && (
            <div className="cmd-grid">
              <div className="cmd-col">
                <section className="cmd-card">
                  <h3>{t("drawer.people")}</h3>
                  <p>
                    {t("drawer.occupancy", { n: fmtNumber(Math.round(zone.occupancy), lang, 0) })}
                    {presence != null && (
                      <>
                        <br />
                        {presence ? t("drawer.presenceYes") : t("drawer.presenceNo")}
                      </>
                    )}
                  </p>
                  <div className="small muted">{t("drawer.residents", { unit: unitText(zone, ctx, t) })}</div>
                  {residents.length === 0 ? (
                    <p className="muted small">{t("drawer.noResidents")}</p>
                  ) : (
                    <ul className="drawer-list">
                      {residents.map((r) => (
                        <li key={r.user_id}>
                          <span>{r.display_name}</span>
                          {r.status && <span className={`pp-status ${r.status} small`}>{tokenLabel(t, "pstatus", r.status)}</span>}
                        </li>
                      ))}
                    </ul>
                  )}
                </section>
              </div>
              <div className="cmd-col">
                <section className="cmd-card">
                  <h3>{t("priority.title")}</h3>
                  {priority.length === 0 ? (
                    <p className="muted small">{incident ? t("cmd.noPriority") : t("cmd.onlyDuringIncident")}</p>
                  ) : (
                    <div className="drawer-priority">
                      {priority.map((p) => (
                        <PersonCard key={p.care_profile_id} person={p} />
                      ))}
                    </div>
                  )}
                  {incident && (
                    <div className="priority-privacy muted small">
                      <LockIcon />
                      {t("priority.privacy")}
                    </div>
                  )}
                </section>
              </div>
            </div>
          )}

          {tab === "evacuation" && (
            <div className="cmd-grid">
              {routes.length === 0 && <p className="muted">{t("drawer.noRoutes")}</p>}
              {routes.map((r) => {
                const through = r.path.includes(z.id);
                return (
                  <section key={r.id} className="cmd-card">
                    <h3>
                      <RouteIcon /> {r.label}
                    </h3>
                    <p className={through && dangerous ? "t-danger" : through ? "" : "t-ok"}>
                      {through && dangerous && <WarningIcon />}{" "}
                      {t(through ? (dangerous ? "drawer.routeThroughDanger" : "drawer.routeThrough") : "drawer.routeAvoids", { route: r.label })}
                    </p>
                    {(r.waypoints ?? []).length > 0 && (
                      <ol className="route-steps big">
                        {r.waypoints!.map((w) => (
                          <li key={w.id} className={w.id === z.id ? "here" : undefined}>
                            <b>{w.label}</b>
                            {w.hint && <div className="muted small">{w.hint}</div>}
                          </li>
                        ))}
                      </ol>
                    )}
                  </section>
                );
              })}
            </div>
          )}

          {tab === "timeline" && (
            <div className="cmd-grid">
              <section className="cmd-card">
                <h3>{t("cmd.crossings")}</h3>
                {!incident ? (
                  <p className="muted small">{t("cmd.noIncident")}</p>
                ) : cross.length === 0 ? (
                  <p className="muted small">{t("cmd.noCrossings")}</p>
                ) : (
                  <ul className="drawer-list">
                    {cross.map((c) => (
                      <li key={`${c.sensor.id}-${c.channel.metric.field}`}>
                        <span>
                          <b>{fmtClock(c.t, lang)}</b> · {c.sensor.name} · {t(c.channel.metric.label)}
                        </span>
                        <span className="small t-attention">
                          {t(c.channel.metric.refs![0].label)} {fmtNumber(c.channel.warn!, lang, c.channel.metric.digits)}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </section>
              <section className="cmd-card">
                <h3>{t("cmd.events")}</h3>
                {incident ? <IncidentTimeline events={events.data ?? []} /> : <p className="muted small">{t("cmd.noIncident")}</p>}
              </section>
            </div>
          )}
        </div>
      </div>
    </>
  );
}

