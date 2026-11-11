/**
 * Device health for the manager, from the sensor nodes themselves: counters (sensors, online,
 * offline, never tested), one line per apartment (online x/y, weakest Wi-Fi, newest test) and
 * then only the sensors that need attention: offline, no recent data, sensor fault / invalid
 * reading / warming up, weak Wi-Fi, a failed or unanswered test, a closed valve, an alarm
 * sounding. Those are a matrix (one row per apartment, one box per sensor, a legend that groups by
 * reason) once there are more than a few; a few stay as text rows. Roles allowed in Administration
 * open the devices of that apartment from here.
 */
import { useState, type ReactNode } from "react";
import { Link } from "react-router-dom";

import { useNodes, useSensorTrust } from "../api/hooks";
import type { CommandRecord, NodeOut, SensorTrust } from "../api/types";
import { useAuth } from "../auth/AuthContext";
import { pluralCategory, useT, type Lang, type TFn } from "../i18n";
import { commandName, lastCommandOutcome, useLiveCommands, type CommandOutcome } from "../lib/commands";
import { fmtNumber } from "../lib/format";
import { deviceToken, trustReasonLabel, trustStateLabel } from "../lib/labels";
import { channelTrust } from "../lib/metrics";
import { pick, pickNum } from "../lib/nodes";
import { setScope, useScope, type Scope } from "../lib/scope";
import { fmtAgo, parseTs } from "../lib/time";
import { OTHER_GROUP, groupByUnit, type UnitGroup } from "../lib/unitGroups";
import { Card } from "./Card";
import { CheckIcon, ChevronRightIcon, DropletIcon, WindIcon } from "./Icons";
import { LastCommandLine } from "./NodeCommands";
import { KIND_ICON } from "./ScopeBar";
import { StateCell, StateLegend } from "./StateGrid";
import { WifiBars } from "./WifiBars";

/** Below this the bars drop to one (WifiBars): the link is likely to drop out. */
const WEAK_DBM = -75;

/** Air channels whose state / valid flags say whether the measurement can be trusted. */
const AIR_CHANNELS = ["co", "gas", "particulate", "climate", "presence"] as const;

type Tone = "danger" | "attention" | "unknown";
const TONE_RANK: Record<Tone, number> = { unknown: 0, attention: 1, danger: 2 };

interface Problem {
  tone: Tone;
  text: string;
  /** the reason without per-sensor values ("offline", not "offline, last seen 3 min ago"): what the legend groups by */
  gist?: string;
}

/** Up to this many sensors needing attention stay text rows; more become the matrix. */
const MATRIX_FROM = 5;

interface Item {
  zoneId: string;
  name: string;
  node: NodeOut;
}

const channelLabel = (ch: string, t: TFn) =>
  ch === "climate" ? t("health.chClimate") : ch === "presence" ? t("health.chPresence") : deviceToken(ch, t);

/** What is wrong with a sensor, worst first (empty: it works). */
function problemsOf(n: NodeOut, last: { outcome: CommandOutcome; command: string | null }, t: TFn, lang: Lang): Problem[] {
  const out: Problem[] = [];
  const doc = n.status;
  if (!n.online) {
    out.push({
      tone: "danger",
      text: n.last_seen_ts ? t("health.pOfflineSince", { ago: fmtAgo(n.last_seen_ts, lang) }) : t("health.pOffline"),
      gist: t("health.pOffline"),
    });
  } else if (!doc) {
    out.push({ tone: "attention", text: t("health.pNoStatus") });
  } else {
    if (n.analysis?.stale) out.push({ tone: "attention", text: t("health.pStale") });
    if (pick(doc, "alarm.sounding") === true && pick(doc, "alarm.self_test") !== true) {
      const hazard = pick(doc, "alarm.hazard");
      out.push({
        tone: "danger",
        text:
          typeof hazard === "string" && hazard !== "none"
            ? t("health.pAlarmFor", { what: deviceToken(hazard, t) })
            : t("health.pAlarm"),
      });
    }
    if (n.kind === "air") {
      const fault: string[] = [];
      const invalid: string[] = [];
      let warming = false;
      for (const ch of AIR_CHANNELS) {
        const trust = channelTrust(doc, ch);
        if (trust === "fault") fault.push(channelLabel(ch, t));
        else if (trust === "invalid") invalid.push(channelLabel(ch, t));
        else if (trust === "warmup") warming = true;
      }
      if (fault.length) out.push({ tone: "attention", text: t("health.pFault", { what: fault.join(", ") }) });
      if (invalid.length) out.push({ tone: "attention", text: t("health.pInvalid", { what: invalid.join(", ") }) });
      const warmS = pickNum(doc, "warmup_remaining_seconds") ?? 0;
      if (warming || warmS > 0) {
        out.push({
          tone: "unknown",
          text: warmS > 0 ? t("health.pWarmupMin", { min: fmtNumber(Math.ceil(warmS / 60), lang, 0) }) : t("health.pWarmup"),
          gist: t("health.pWarmup"),
        });
      }
    } else {
      if (channelTrust(doc, "sensor") === "uninitialized") out.push({ tone: "attention", text: t("health.pUninit") });
      if (pick(doc, "valve.applied") === "closed") out.push({ tone: "attention", text: t("health.pValve") });
    }
    const rssi = pickNum(doc, "wifi.rssi");
    if (rssi != null && rssi < WEAK_DBM) out.push({ tone: "attention", text: t("health.pWifi", { dbm: fmtNumber(rssi, lang, 0) }), gist: t("health.gWifi") });
  }
  // a refused SILENCE (nothing was sounding) says nothing about the device
  if ((last.outcome === "rejected" || last.outcome === "timeout") && last.command !== "SILENCE") {
    const test = last.command === "TEST";
    const key =
      last.outcome === "rejected"
        ? test
          ? "health.pTestFailed"
          : "health.pCmdFailed"
        : test
          ? "health.pTestNoAnswer"
          : "health.pCmdNoAnswer";
    out.push({ tone: last.outcome === "rejected" ? "danger" : "attention", text: t(key, { cmd: commandName(last.command ?? "", t) }) });
  }
  return out.sort((a, b) => TONE_RANK[b.tone] - TONE_RANK[a.tone]);
}

/** Newest alarm test of the sensors (null: none of them was tested lately). */
function newestTest(nodes: NodeOut[]): CommandRecord | null {
  const tests = nodes.map((n) => n.last_command).filter((r): r is CommandRecord => r?.command === "TEST");
  return tests.reduce<CommandRecord | null>(
    (a, r) => (!a || parseTs(r.sent_ts) > parseTs(a.sent_ts) ? r : a),
    null,
  );
}

const plain = (v: string) => v.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();

/** A link to the scoped Devices tab, or plain content for roles without Administration. */
function DevicesLink({ to, admin, className, children }: { to: Scope; admin: boolean; className: string; children: ReactNode }) {
  if (!admin) return <div className={className}>{children}</div>;
  return (
    <Link to="/admin/devices" className={`${className} linked`} onClick={() => setScope(to)}>
      {children}
    </Link>
  );
}

const scopeOf = (g: UnitGroup<Item>, room = "all"): Scope =>
  g.id === OTHER_GROUP ? { unit: "all", room: "all" } : { unit: g.id, room };

/** One apartment's boxes grouped by room, in the order the rooms first appear. */
function roomsOf<T extends { room: string; roomLabel: string }>(cells: T[]): { id: string; label: string; items: T[] }[] {
  const out: { id: string; label: string; items: T[] }[] = [];
  for (const c of cells) {
    const hit = out.find((r) => r.id === c.room);
    if (hit) hit.items.push(c);
    else out.push({ id: c.room, label: c.roomLabel, items: [c] });
  }
  return out;
}

export function DeviceHealthCard() {
  const { t, lang } = useT();
  const { session } = useAuth();
  // same roles as the Administration entry of the top bar
  const admin = session?.role === "hoa_manager" || session?.role === "system_admin" || session?.role === "technician";
  const nodes = useNodes();
  const trust = useSensorTrust();
  const live = useLiveCommands();
  const sc = useScope();
  /** the box whose sentence is printed under the matrix (hovered, focused or tapped last) */
  const [preview, setPreview] = useState<string | null>(null);

  if (!nodes.data || !sc.ready) {
    return (
      <Card title={t("manager.deviceHealth")} className="device-health-card">
        <div className="muted small">{nodes.isError ? t("health.unavailable") : t("common.loading")}</div>
      </Card>
    );
  }

  const items: Item[] = nodes.data.map((n) => ({ zoneId: n.zone_id, name: n.name || n.id, node: n }));
  const groups = groupByUnit(sc.units, sc.rooms, items, t("health.unplaced"));
  const last = (n: NodeOut) => lastCommandOutcome(n, live.get(n.id));
  const trustByNode = new Map((trust.data ?? []).map((item) => [item.node_id, item]));
  const trustProblem = (n: NodeOut): Problem[] => {
    const item: SensorTrust | undefined = trustByNode.get(n.id);
    if (!item) {
      return [{
        tone: "unknown",
        text: trust.isError || trust.data ? t("trust.unavailable") : t("trust.loading"),
      }];
    }
    if (item.state === "ok") return [];
    return [{
      tone: item.state === "lost" ? "danger" : "attention",
      text: t("trust.issue", {
        state: trustStateLabel(item.state, t),
        reason: trustReasonLabel(item.reason, t),
      }),
    }];
  };
  const problems = new Map(nodes.data.map((n) => [n.id, [...problemsOf(n, last(n), t, lang), ...trustProblem(n)]]));
  const num = (v: number) => fmtNumber(v, lang, 0);
  const all = nodes.data.length;
  const online = nodes.data.filter((n) => n.online).length;
  const untested = nodes.data.filter((n) => last(n).outcome === "none").length;
  const trustCounts = (trust.data ?? []).reduce(
    (counts, item) => ({ ...counts, [item.state]: counts[item.state] + 1 }),
    { ok: 0, suspect: 0, lost: 0 },
  );

  const unitLevel = (ns: NodeOut[]) => {
    if (!ns.length) return "unknown";
    const tones = ns.flatMap((n) => problems.get(n.id) ?? []).map((p) => p.tone);
    return tones.includes("danger") ? "danger" : tones.includes("attention") ? "attention" : "ok";
  };

  const attention = groups.flatMap((g) =>
    g.rooms.flatMap((r) =>
      r.nodes
        .filter((i) => (problems.get(i.node.id) ?? []).length > 0)
        .map((i) => {
          const ps = problems.get(i.node.id) ?? [];
          // the sensor's name usually starts with its room ("Baie · aer"): no need to repeat it
          const where = [i.name, plain(i.name).startsWith(plain(r.label)) ? null : r.label, g.label].filter(Boolean).join(" · ");
          const roomKind = sc.rooms.find((room) => room.id === r.id)?.kind ?? "";
          return { id: i.node.id, group: g, room: r.id, roomLabel: r.label, where, tone: ps[0].tone, text: ps.map((p) => p.text).join(", "), ps, water: i.node.kind === "water", roomKind };
        }),
    ),
  );

  // one row per apartment for the matrix, in the order of the summary rows above
  const rows = groups
    .map((g) => ({ group: g, items: attention.filter((a) => a.group.id === g.id) }))
    .filter((r) => r.items.length > 0);
  // the legend: one line per distinct reason with the number of sensors it affects, worst first
  const reasons = new Map<string, { tone: Tone; gist: string; count: number }>();
  for (const a of attention) {
    for (const gist of new Set(a.ps.map((p) => p.gist ?? p.text))) {
      const tone = a.ps.filter((p) => (p.gist ?? p.text) === gist).reduce<Tone>((w, p) => (TONE_RANK[p.tone] > TONE_RANK[w] ? p.tone : w), "unknown");
      const key = `${tone}|${gist}`;
      const hit = reasons.get(key);
      if (hit) hit.count += 1;
      else reasons.set(key, { tone, gist, count: 1 });
    }
  }
  const legend = [...reasons.entries()]
    .sort(([, a], [, b]) => TONE_RANK[b.tone] - TONE_RANK[a.tone] || b.count - a.count)
    .map(([key, r]) => ({
      key,
      mark: <span className={`lvl ${r.tone}`} aria-hidden="true" />,
      text: (
        <>
          <b>{t(`rooms.sensorCount.${pluralCategory(lang, r.count)}`, { n: num(r.count) })}</b>
          <span className="muted"> · </span>
          <span className={`t-${r.tone}`}>{r.gist}</span>
        </>
      ),
    }));

  return (
    <Card title={t("manager.deviceHealth")} className="device-health-card">
      <div className="health-head">
        <div className="devs-counter">
          <b>{t(`rooms.sensorCount.${pluralCategory(lang, all)}`, { n: num(all) })}</b>
          <span className="t-ok">
            <span className="sep">·</span>
            {t("devs.online", { n: num(online) })}
          </span>
          <span className={all - online ? "t-danger" : "muted"}>
            <span className="sep">·</span>
            {t("devs.offline", { n: num(all - online) })}
          </span>
          <span className={untested ? "t-attention" : "muted"}>
            <span className="sep">·</span>
            {t(`devs.untested.${pluralCategory(lang, untested)}`, { n: num(untested) })}
          </span>
        </div>
        <div className={`small ${trust.isError || !trust.data ? "t-attention" : "muted"}`}>
          <b>{t("trust.title")}:</b>{" "}
          {trust.data?.length || all === 0
            ? t("trust.summary", trustCounts)
            : t(trust.isError || trust.data ? "trust.unavailable" : "trust.loading")}
        </div>
        <span className="spacer" />
        {admin && (
          <Link to="/admin/devices" className="small link-arrow" onClick={() => setScope({ unit: "all", room: "all" })}>
            {t("health.devicesLink")}
            <ChevronRightIcon />
          </Link>
        )}
      </div>

      <ul className="health-units">
        {groups.map((g) => {
          const ns = g.nodes.map((i) => i.node);
          const on = ns.filter((n) => n.online).length;
          const rssi = ns
            .filter((n) => n.online)
            .map((n) => pickNum(n.status, "wifi.rssi"))
            .filter((v): v is number => v != null);
          const level = unitLevel(ns);
          return (
            <li key={g.id}>
              <DevicesLink to={scopeOf(g)} admin={admin} className="health-unit">
                <span className="health-unit-name">
                  <span className={`lvl ${level}`} aria-hidden="true" />
                  {g.label}
                </span>
                {ns.length === 0 ? (
                  <span className="muted small">{t("health.noSensors")}</span>
                ) : (
                  <>
                    <span className={on < ns.length ? "t-danger" : "t-ok"}>
                      {t("health.onlineOf", { online: num(on), total: num(ns.length) })}
                    </span>
                    <span className="health-wifi" title={t("health.weakestWifi")}>
                      <WifiBars rssi={rssi.length ? Math.min(...rssi) : null} />
                    </span>
                    <span className="health-test small">
                      <LastCommandLine rec={newestTest(ns)} lang={lang} t={t} />
                    </span>
                  </>
                )}
              </DevicesLink>
            </li>
          );
        })}
      </ul>

      <h4 className="health-sub">{t("health.attention")}</h4>
      {attention.length === 0 ? (
        <div className="health-allgood">
          <CheckIcon /> {t("health.allGood")}
        </div>
      ) : attention.length >= MATRIX_FROM ? (
        <>
          <ul className="hm">
            {rows.map(({ group, items: cells }) => (
              <li key={group.id} className="hm-row">
                <span className="hm-name">
                  <span className={`lvl ${cells.some((c) => c.tone === "danger") ? "danger" : cells.some((c) => c.tone === "attention") ? "attention" : "unknown"}`} aria-hidden="true" />
                  {group.label}
                </span>
                <div className="hm-cells">
                  {roomsOf(cells).map((rm) => {
                    const KindIcon = KIND_ICON[rm.items[0].roomKind] as (typeof KIND_ICON)[string] | undefined;
                    return (
                      <div key={rm.id} className="hm-room" role="group" aria-label={rm.label}>
                        <span className="hm-room-name" title={rm.label} aria-hidden="true">
                          {KindIcon && <KindIcon />}
                          <span className="hm-room-text">{rm.label}</span>
                        </span>
                        {rm.items.map((c) => {
                          // the room's name and icon label the group; the box says air (wind) or water (droplet)
                          const Mark = c.water ? DropletIcon : WindIcon;
                          const label = `${c.where} — ${c.text}`;
                          return (
                            <StateCell
                              key={c.id}
                              tone={c.tone}
                              label={label}
                              to={admin ? "/admin/devices" : undefined}
                              onNavigate={() => setScope(scopeOf(c.group, c.room))}
                              onPreview={setPreview}
                              previewed={preview === label}
                            >
                              <Mark />
                            </StateCell>
                          );
                        })}
                      </div>
                    );
                  })}
                </div>
              </li>
            ))}
          </ul>
          <div className="hm-sentence small" aria-live="polite">
            {preview ?? <span className="muted">{t("health.previewHint")}</span>}
          </div>
          <StateLegend items={legend} stacked />
        </>
      ) : (
        <ul className="health-problems">
          {attention.map((p) => (
            <li key={p.id}>
              <DevicesLink to={scopeOf(p.group, p.room)} admin={admin} className="health-problem">
                <span className={`lvl ${p.tone}`} aria-hidden="true" />
                <span>
                  <b>{p.where}</b> — <span className={`t-${p.tone}`}>{p.text}</span>
                </span>
              </DevicesLink>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
