/**
 * Environment of the building for the manager: the building headline, then one row per
 * apartment (scope bar order, common areas last) with its worst status and what the sensors
 * measure there now: approximate temperature / humidity (inside the PMS5003T), the air quality
 * the hub derives, the highest CO, the highest gas reading as a share of the device's alarm
 * threshold (raw MQ5 ADC, never ppm) and water (leaks, closed valves). Under it only the rooms
 * that are not OK. A row opens that apartment on /sensors. Without raw node data (a role that
 * cannot read nodes) the rows fall back to the hub's analysis.
 */
import { Link } from "react-router-dom";

import { useNodes, useSummary } from "../api/hooks";
import type { AnalysisLevel, BuildingSummary, Indicator, NodeKind, NodeOut, NodeStatusDoc } from "../api/types";
import { useT, type Lang, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import { levelLabel } from "../lib/labels";
import { METRICS, currentValue, type Level, type Metric } from "../lib/metrics";
import { pick, pickNum } from "../lib/nodes";
import { setScope, useScope } from "../lib/scope";
import { OTHER_GROUP, groupByUnit, type RoomGroup, type UnitGroup } from "../lib/unitGroups";
import { Card } from "./Card";
import { StatusPill } from "./StatusPill";

const RANK: Record<Level, number> = { unknown: 0, none: 0, ok: 1, attention: 2, danger: 3 };
const worse = (a: Level, b: Level): Level => (RANK[b] > RANK[a] ? b : a);
const alarming = (l: Level) => RANK[l] >= RANK.attention;

/** One sensor as this card sees it: the raw document when the hub sends it, else analysis only. */
interface EnvNode {
  id: string;
  name: string;
  zoneId: string;
  kind: NodeKind;
  online: boolean;
  /** online and reporting: its values are current */
  live: boolean;
  status: AnalysisLevel;
  headline: string;
  indicators: Indicator[];
  doc: NodeStatusDoc | null;
}

interface Finding {
  level: Level;
  text: string;
}

interface Fact {
  key: string;
  label: string;
  value: string | null;
  sub?: string;
  level: Level;
  /** the sub line's own level (a closed valve under "No leaks") */
  subLevel?: Level;
  approx?: boolean;
  hint?: string;
}

function fromNodes(nodes: NodeOut[], summary: BuildingSummary | undefined): EnvNode[] {
  // the summary is refreshed by node events: its status wins, like on the scope bar
  const status = new Map<string, AnalysisLevel>();
  for (const z of summary?.zones ?? []) for (const n of z.nodes) status.set(n.node_id, n.status);
  return nodes.map((n) => ({
    id: n.id,
    name: n.name || n.id,
    zoneId: n.zone_id,
    kind: n.kind,
    online: n.online,
    live: n.online && !n.analysis?.stale,
    status: status.get(n.id) ?? n.analysis?.status ?? "unknown",
    headline: n.analysis?.headline ?? "",
    indicators: n.analysis?.indicators ?? [],
    doc: n.status,
  }));
}

function fromSummary(summary: BuildingSummary): EnvNode[] {
  return summary.zones.flatMap((z) =>
    z.nodes.map((n) => ({
      id: n.node_id,
      name: n.name || n.node_id,
      zoneId: z.zone_id,
      kind: n.kind,
      online: n.online,
      live: n.online && !n.stale,
      status: n.status,
      headline: n.headline,
      indicators: n.indicators,
      doc: null,
    })),
  );
}

const indicator = (n: EnvNode, key: string) => n.indicators.find((i) => i.key === key);
const aqiOf = (i: Indicator) => Number(/\d+/.exec(i.detail ?? "")?.[0] ?? -1);

/** Worst graded indicator of a key over the sensors (then the higher AQI, for air quality). */
function worstIndicator(nodes: EnvNode[], key: string): Indicator | null {
  let w: Indicator | null = null;
  for (const n of nodes) {
    const i = indicator(n, key);
    if (!i || i.level === "unknown") continue;
    if (!w || RANK[i.level] > RANK[w.level] || (RANK[i.level] === RANK[w.level] && aqiOf(i) > aqiOf(w))) w = i;
  }
  return w;
}

/** A metric's current value with the device's own grading of it. */
function graded(m: Metric, doc: unknown): { value: number; level: Level } | null {
  const { value } = currentValue(m, doc);
  return value == null ? null : { value, level: m.level(value, doc) };
}

/** Raw MQ5 reading as a share (0..1, like the floor plan) of the device's alarm (danger) threshold. */
function gasShare(doc: unknown): { value: number; level: Level } | null {
  const g = graded(METRICS.gas, doc);
  const danger = pickNum(doc, "gas.danger_adc");
  if (!g || !danger) return null;
  return { value: Math.max(0, Math.min(1, g.value / danger)), level: g.level };
}

/** The reading with the worst grading, then the highest value. */
function worstOf(vals: ({ value: number; level: Level } | null)[]) {
  let w: { value: number; level: Level } | null = null;
  for (const v of vals) {
    if (v && (!w || RANK[v.level] > RANK[w.level] || (RANK[v.level] === RANK[w.level] && v.value > w.value))) w = v;
  }
  return w;
}

const pct = (share: number, lang: Lang) => fmtNumber(Math.round(share * 100), lang, 0);

const wet = (n: EnvNode) => (n.doc ? pick(n.doc, "sensor.state") === "wet" : indicator(n, "leak")?.level === "danger");
const latched = (n: EnvNode) =>
  n.doc ? pick(n.doc, "leak_latched") === true && !wet(n) : indicator(n, "leak")?.level === "attention";
const dry = (n: EnvNode) => (n.doc ? pick(n.doc, "sensor.state") === "dry" && !latched(n) : indicator(n, "leak")?.level === "ok");
const valveClosed = (n: EnvNode) =>
  n.doc ? pick(n.doc, "valve.applied") === "closed" : indicator(n, "valve")?.level === "attention";

/** Why a sensor's room is not OK, worst first; the hub's headline when nothing measured explains it. */
function findings(n: EnvNode, t: TFn, lang: Lang): Finding[] {
  if (!n.online) return [{ level: "unknown", text: t(n.kind === "water" ? "env.cOfflineWater" : "env.cOfflineAir") }];
  const out: Finding[] = [];
  if (n.doc && n.live) {
    if (n.kind === "air") {
      const gas = gasShare(n.doc);
      if (gas && alarming(gas.level)) out.push({ level: gas.level, text: t("env.cGas", { pct: pct(gas.value, lang) }) });
      const co = graded(METRICS.co, n.doc);
      if (co && alarming(co.level)) out.push({ level: co.level, text: t("env.cCo", { ppm: fmtNumber(co.value, lang, 0) }) });
      const aq = indicator(n, "air_quality");
      if (aq && alarming(aq.level)) out.push({ level: aq.level, text: t("env.cAir", { value: aq.value.toLowerCase() }) });
      const comfort = indicator(n, "comfort");
      if (comfort && alarming(comfort.level)) out.push({ level: comfort.level, text: comfort.value.toLowerCase() });
    } else if (wet(n)) {
      out.push({ level: "danger", text: t("env.cLeak") });
    } else if (latched(n)) {
      out.push({ level: "attention", text: t("env.cLeakLatched") });
    }
  }
  if (n.kind === "water" && n.doc && valveClosed(n)) out.push({ level: "attention", text: t("env.cValve") });
  // whatever else the hub flags (sensor fault, weak Wi-Fi, ...; without raw data: everything)
  if (!out.length && alarming(n.status) && n.headline) out.push({ level: n.status, text: n.headline });
  return out.sort((a, b) => RANK[b.level] - RANK[a.level]);
}

/** Worst analysis status of the online sensors, like the scope bar; unknown when none is online. */
function statusOf(nodes: EnvNode[]): Level {
  return nodes.filter((n) => n.online).reduce<Level>((w, n) => worse(w, n.status), "unknown");
}

function facts(group: UnitGroup<EnvNode>, t: TFn, lang: Lang): Fact[] {
  const air = group.nodes.filter((n) => n.kind === "air" && n.live);
  const raw = air.filter((n) => n.doc);
  const water = group.nodes.filter((n) => n.kind === "water");

  const climate = (m: Metric): { value: string | null; hint: string } => {
    const per = group.rooms.flatMap((r) =>
      r.nodes
        .filter((n) => n.kind === "air" && n.live && n.doc)
        .map((n) => ({ room: r.label, v: currentValue(m, n.doc).value }))
        .filter((x): x is { room: string; v: number } => x.v != null),
    );
    const fmt = (v: number) => `${fmtNumber(v, lang, m.digits, m.fixed)} ${m.unit}`;
    const mean = per.length ? per.reduce((s, x) => s + x.v, 0) / per.length : null;
    const rooms = per.map((x) => `${x.room} ≈${fmt(x.v)}`).join(" · ");
    return { value: mean == null ? null : fmt(mean), hint: [t("tile.climateHint"), rooms].filter(Boolean).join("\n") };
  };
  const temp = climate(METRICS.temperature);
  const hum = climate({ ...METRICS.humidity, digits: 0, fixed: false });

  const aq = worstIndicator(air, "air_quality");

  let co: Fact = { key: "co", label: t("env.fCo"), value: null, level: "unknown", hint: t("tile.coHint") };
  let gas: Fact = { key: "gas", label: t("env.fGas"), value: null, level: "unknown", hint: t("env.gasHint") };
  if (raw.length) {
    const c = worstOf(raw.map((n) => graded(METRICS.co, n.doc)));
    if (c) co = { ...co, value: `${fmtNumber(c.value, lang, 0)} ppm`, level: c.level };
    const g = worstOf(raw.map((n) => gasShare(n.doc)));
    if (g) gas = { ...gas, value: `${pct(g.value, lang)}%`, sub: t("env.ofThreshold"), level: g.level };
  } else {
    const c = worstIndicator(air, "co");
    if (c) co = { ...co, value: c.value, level: c.level };
    const g = worstIndicator(air, "gas");
    if (g) gas = { ...gas, value: g.value, level: g.level };
  }

  const roomsWhere = (keep: (n: EnvNode) => boolean) =>
    group.rooms.filter((r) => r.nodes.some((n) => n.kind === "water" && keep(n))).map((r) => r.label).join(", ");
  const liveWater = (f: (n: EnvNode) => boolean) => (n: EnvNode) => n.live && f(n);
  const wetIn = roomsWhere(liveWater(wet));
  const latchedIn = roomsWhere(liveWater(latched));
  const closedIn = roomsWhere((n) => n.online && valveClosed(n));
  let waterFact: Fact = { key: "water", label: t("env.fWater"), value: null, level: "unknown" };
  if (wetIn) waterFact = { ...waterFact, value: t("env.leakIn", { rooms: wetIn }), level: "danger" };
  else if (latchedIn) waterFact = { ...waterFact, value: t("env.leakLatchedIn", { rooms: latchedIn }), level: "attention" };
  else if (water.some(liveWater(dry))) waterFact = { ...waterFact, value: t("env.noLeak"), level: "ok" };
  if (closedIn) waterFact = { ...waterFact, sub: t("env.valveClosedIn", { rooms: closedIn }), subLevel: "attention" };

  return [
    { key: "temp", label: t("env.fTemp"), value: temp.value, approx: true, level: "none", hint: temp.hint },
    { key: "hum", label: t("env.fHumidity"), value: hum.value, approx: true, level: "none", hint: hum.hint },
    { key: "air", label: t("env.fAir"), value: aq?.value ?? null, sub: aq?.detail ?? undefined, level: aq?.level ?? "unknown" },
    co,
    gas,
    ...(water.length ? [waterFact] : []),
  ];
}

interface RoomChip {
  id: string;
  level: Level;
  text: string;
}

function roomChips(rooms: RoomGroup<EnvNode>[], t: TFn, lang: Lang): RoomChip[] {
  return rooms.flatMap((r) => {
    const fs = r.nodes.flatMap((n) => findings(n, t, lang)).sort((a, b) => RANK[b.level] - RANK[a.level]);
    if (!fs.length) return [];
    const level = fs.reduce<Level>((w, f) => worse(w, f.level), "unknown");
    return [{ id: r.id, level, text: `${r.label}: ${fs.map((f) => f.text).join(", ")}` }];
  });
}

const tone = (l: Level) => (l === "attention" || l === "danger" ? `t-${l}` : "");

function UnitRow({ group }: { group: UnitGroup<EnvNode> }) {
  const { t, lang } = useT();
  const chips = roomChips(group.rooms, t, lang);
  const level = chips.reduce<Level>((w, c) => (c.level === "unknown" ? w : worse(w, c.level)), statusOf(group.nodes));
  const open = () => setScope(group.id === OTHER_GROUP ? { unit: "all", room: "all" } : { unit: group.id, room: "all" });

  return (
    <li>
      <Link to="/sensors" className={`env-unit lvl-${level}`} onClick={open} title={t("env.openUnit", { unit: group.label })}>
        <span className="env-unit-head">
          <span className={`lvl ${level}`} aria-hidden="true" />
          <span className="env-unit-name">{group.label}</span>
          <span className={`env-unit-status ${level === "ok" ? "t-ok" : `t-${level}`}`}>{levelLabel(level, t)}</span>
        </span>
        {group.nodes.length === 0 ? (
          <span className="muted small">{t("env.noSensors")}</span>
        ) : (
          <dl className="env-facts">
            {facts(group, t, lang).map((f) => (
              <div key={f.key} title={f.hint} className={f.key === "water" ? "wide" : undefined}>
                <dt>{f.label}</dt>
                <dd className={tone(f.level)}>
                  {f.value == null ? <span className="muted">—</span> : `${f.approx ? "≈" : ""}${f.value}`}
                  {f.sub && <span className={`env-fact-sub ${f.subLevel ? tone(f.subLevel) : ""}`}>{f.sub}</span>}
                </dd>
              </div>
            ))}
          </dl>
        )}
        {chips.length > 0 && (
          <span className="env-chips">
            {chips.map((c) => (
              <span key={c.id} className={`env-chip lvl-${c.level}`}>
                <span className={`lvl ${c.level}`} aria-hidden="true" />
                {c.text}
              </span>
            ))}
          </span>
        )}
      </Link>
    </li>
  );
}

export function EnvironmentCard() {
  const { t } = useT();
  const summary = useSummary();
  const nodes = useNodes();
  const sc = useScope();
  const s = summary.data;

  const env = nodes.data ? fromNodes(nodes.data, s) : nodes.isError && s ? fromSummary(s) : null;
  const groups = env && sc.ready ? groupByUnit(sc.units, sc.rooms, env, t("health.unplaced")) : null;

  return (
    <Card title={t("env.title")}>
      {!s ? (
        <div className="muted small">{summary.isError ? t("env.unavailable") : t("common.loading")}</div>
      ) : (
        <div className="row">
          <StatusPill state={s.status} label={levelLabel(s.status, t)} />
          <div className="grow">
            <div>{s.headline}</div>
            <div className="muted small">{t("env.nodesOnline", { online: s.nodes_online, total: s.nodes_total })}</div>
          </div>
          <Link to="/sensors" className="small">
            {t("env.sensorsLink")}
          </Link>
        </div>
      )}
      {groups && groups.length > 0 && (
        <ul className="env-units">
          {groups.map((g) => (
            <UnitRow key={g.id} group={g} />
          ))}
        </ul>
      )}
    </Card>
  );
}
