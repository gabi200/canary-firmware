/**
 * Each room against its own learned normal (frozen median / MAD per metric, hour buckets once there
 * is enough history). Evidence only: the score is a heuristic, not a probability, and the alarm
 * thresholds are unchanged. Seed references are labelled as simulated.
 *
 * A matrix: rooms down, metrics across, one small state mark per cell. Every cell carries the full
 * sentence (room, metric, status, samples / value vs usual / hour / seed) as tooltip and accessible
 * name; the numbers are shown as text only for the unusual cells, listed under the matrix.
 * Rooms are grouped by apartment. When every cell shares one state (usually "still learning" on a
 * new building) the table collapses to one summary line, with the sample counts of the learning
 * cells, and a disclosure that shows the table.
 */
import { Fragment, useState } from "react";

import { useZoneNormal, useZones } from "../api/hooks";
import type { MetricNormal, NormalStatus } from "../api/types";
import { isMsgKey, pluralCategory, useT, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import { buildZoneNames, prettyId, zoneLabel } from "../lib/labels";
import { useScope } from "../lib/scope";
import { Card } from "./Card";
import { ArrowDownIcon, ArrowUpIcon, CheckIcon, DashedCircleIcon, DashedLineIcon } from "./Icons";
import { KIND_ICON } from "./ScopeBar";
import { StateCell, StateLegend, StateMark, type CellTone } from "./StateGrid";

const PILL: Record<NormalStatus, string> = {
  usual: "quiet",
  unusual_high: "attention",
  unusual_low: "attention",
  learning: "unknown",
  no_recent_data: "unknown",
};

const TONE: Record<NormalStatus, CellTone> = {
  usual: "quiet",
  unusual_high: "attention",
  unusual_low: "attention",
  learning: "unknown",
  no_recent_data: "none",
};

const MARK: Record<NormalStatus, () => JSX.Element> = {
  usual: () => <CheckIcon />,
  unusual_high: () => <ArrowUpIcon />,
  unusual_low: () => <ArrowDownIcon />,
  learning: () => <DashedCircleIcon />,
  no_recent_data: () => <DashedLineIcon />,
};

/** Worst first, the order of the legend. */
const STATUS_ORDER: NormalStatus[] = ["unusual_high", "unusual_low", "usual", "learning", "no_recent_data"];

/** The usual metric order; anything else follows in the order it first appears. */
const METRIC_ORDER = ["co", "combustible_gas", "particulate"];

const metricName = (type: string, t: TFn) => t(`sensor.${type}` as Parameters<TFn>[0]);
/** Column header: the short name when there is one (the full name is the abbr's title). */
const metricShort = (type: string, t: TFn) => {
  const key = `short.${type}`;
  return isMsgKey(key) ? t(key) : metricName(type, t);
};

export function ZoneNormalCard() {
  const { t, lang } = useT();
  const normal = useZoneNormal();
  const zones = useZones();
  const sc = useScope();
  const [open, setOpen] = useState(false);
  if (normal.fetchStatus === "idle" && !normal.data) return null; // not asked for this role

  const names = buildZoneNames(zones.data);
  const kindOf = new Map((zones.data ?? []).map((z) => [z.id, z.kind]));
  const rooms = (normal.data?.zones ?? [])
    .filter((z) => z.metrics.length > 0)
    .map((z) => ({
      id: z.zone_id,
      // the app-wide name (a label several rooms share gets its apartment), the API's own label otherwise
      name: names.has(z.zone_id) ? zoneLabel(names, z.zone_id) : z.label || z.zone_id,
      /** the room alone: it sits under its apartment's header row */
      short: z.label || prettyId(z.zone_id),
      kind: kindOf.get(z.zone_id) ?? "",
      byType: new Map(z.metrics.map((m) => [m.sensor_type, m])),
    }));
  const metrics = [...new Set(rooms.flatMap((r) => [...r.byType.keys()]))].sort((a, b) => {
    const ia = METRIC_ORDER.indexOf(a);
    const ib = METRIC_ORDER.indexOf(b);
    return (ia < 0 ? METRIC_ORDER.length : ia) - (ib < 0 ? METRIC_ORDER.length : ib);
  });

  // apartments in the scope bar's order, their rooms in its order; rooms it does not know come last
  const unitRank = new Map(sc.units.map((u, i) => [u.id, i]));
  const roomRank = new Map(sc.rooms.map((r, i) => [r.id, i]));
  const unitOfRoom = new Map(sc.rooms.map((r) => [r.id, r.unitId]));
  const unitLabelOf = new Map(sc.units.map((u) => [u.id, u.label]));
  rooms.sort((a, b) => (roomRank.get(a.id) ?? 1e6) - (roomRank.get(b.id) ?? 1e6));
  const unitGroups: { id: string; label: string; rooms: typeof rooms }[] = [];
  for (const r of rooms) {
    const id = unitOfRoom.get(r.id) ?? "";
    let g = unitGroups.find((x) => x.id === id);
    if (!g) {
      g = { id, label: id ? (unitLabelOf.get(id) ?? prettyId(id)) : t("health.unplaced"), rooms: [] };
      unitGroups.push(g);
    }
    g.rooms.push(r);
  }
  unitGroups.sort((a, b) => (unitRank.get(a.id) ?? 1e6) - (unitRank.get(b.id) ?? 1e6));

  const num = (v: number) => fmtNumber(v, lang, v < 10 ? 1 : 0);
  /** the numbers behind a status: samples while learning, value vs usual otherwise, hour bucket, seed */
  const detail = (m: MetricNormal) =>
    [
      m.status === "learning"
        ? t("normal.learning", { n: m.n })
        : m.value != null && m.median != null && m.score != null
          ? t("normal.vs", { value: num(m.value), median: num(m.median), score: fmtNumber(m.score, lang, 1) })
          : null,
      m.hour != null && m.hour >= 0 ? t("normal.hour", { hour: m.hour }) : null,
      m.source === "seed" ? t("normal.seed") : null,
    ].filter((v): v is string => !!v);
  const sentence = (room: string, m: MetricNormal) =>
    [`${room} · ${metricName(m.sensor_type, t)}: ${t(`normal.status.${m.status}`)}`, ...detail(m)].join(" · ");

  const cells = rooms.flatMap((r) => [...r.byType.values()].map((m) => ({ room: r, m })));
  const counts = new Map<NormalStatus, number>();
  for (const { m } of cells) counts.set(m.status, (counts.get(m.status) ?? 0) + 1);
  const seeds = cells.filter(({ m }) => m.source === "seed").length;
  const unusual = cells.filter(({ m }) => m.status === "unusual_high" || m.status === "unusual_low");
  // how far the learning cells are: their fewest to most samples (the API does not say how many are needed)
  const learningN = cells.filter(({ m }) => m.status === "learning").map(({ m }) => m.n);
  const samplesText =
    learningN.length === 0
      ? ""
      : Math.min(...learningN) === Math.max(...learningN)
        ? t("normal.learning", { n: fmtNumber(learningN[0], lang, 0) })
        : t("normal.samplesRange", { min: fmtNumber(Math.min(...learningN), lang, 0), max: fmtNumber(Math.max(...learningN), lang, 0) });
  const sameState = counts.size === 1 ? [...counts.keys()][0] : null;
  const collapsed = sameState != null && !open;

  const legend = [
    ...STATUS_ORDER.filter((s) => counts.has(s)).map((s) => {
      const Mark = MARK[s];
      return {
        key: s,
        mark: (
          <StateMark tone={TONE[s]}>
            <Mark />
          </StateMark>
        ),
        text: `${t(`normal.status.${s}`)} ${fmtNumber(counts.get(s) ?? 0, lang, 0)}${s === "learning" ? ` · ${samplesText}` : ""}`,
      };
    }),
    ...(seeds > 0 ? [{ key: "seed", mark: <StateMark tone="unknown" seed />, text: t("normal.seed") }] : []),
  ];

  return (
    <Card title={t("normal.title")} className="zone-normal-card">
      <div className="muted small" style={{ marginBottom: 8 }}>{t("normal.caveat")}</div>
      {normal.isError && <div className="muted small">{t("normal.unavailable")}</div>}
      {!normal.data && !normal.isError && <div className="muted small">{t("common.loading")}</div>}
      {normal.data && cells.length === 0 && <div className="muted small">{t("normal.none")}</div>}
      {cells.length > 0 && sameState != null && (
        <div className="nm-summary">
          <StateMark tone={TONE[sameState]}>
            {(() => {
              const Mark = MARK[sameState];
              return <Mark />;
            })()}
          </StateMark>
          <span className="nm-summary-text">
            <b>{t(`normal.sameState.${pluralCategory(lang, cells.length)}`, { n: fmtNumber(cells.length, lang, 0), status: t(`normal.status.${sameState}`) })}</b>
            {sameState === "learning" && <span className="muted nm-samples"> · {samplesText}</span>}
          </span>
          <button type="button" className="btn small" aria-expanded={open} aria-controls="nm-table-region" onClick={() => setOpen(!open)}>
            {open ? t("normal.hideRooms") : t("normal.showRooms")}
          </button>
        </div>
      )}
      {/* the summary replaces the legend, but the simulated-reference note must stay while any cell is a seed */}
      {cells.length > 0 && sameState != null && seeds > 0 && <StateLegend items={legend.filter((i) => i.key === "seed")} />}
      {cells.length > 0 && !collapsed && (
        <>
          <div className="nm-scroll" id="nm-table-region" role="region" aria-label={t("normal.title")} tabIndex={0}>
            <table className="nm-table">
              <caption className="sr-only">{t("normal.title")}</caption>
              <thead>
                <tr>
                  <th scope="col">{t("normal.colRoom")}</th>
                  {metrics.map((type) => (
                    <th scope="col" key={type}>
                      <abbr title={metricName(type, t)}>{metricShort(type, t)}</abbr>
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {unitGroups.map((g) => (
                  <Fragment key={g.id || "_other"}>
                    <tr className="nm-unit">
                      <th scope="colgroup" colSpan={metrics.length + 1}>{g.label}</th>
                    </tr>
                    {g.rooms.map((r) => {
                      const KindIcon = KIND_ICON[r.kind] as (typeof KIND_ICON)[string] | undefined;
                      return (
                        <tr key={r.id}>
                          <th scope="row">
                            <span className="nm-room">
                              {KindIcon && <KindIcon />}
                              {r.short}
                            </span>
                          </th>
                          {metrics.map((type) => {
                            const m = r.byType.get(type);
                            if (!m) {
                              const none = `${r.name} · ${metricName(type, t)}: ${t("normal.noSensor")}`;
                              return (
                                <td key={type} title={none}>
                                  <span className="sr-only">{none}</span>
                                </td>
                              );
                            }
                            const Mark = MARK[m.status];
                            return (
                              <td key={type}>
                                <StateCell tone={TONE[m.status]} label={sentence(r.name, m)} seed={m.source === "seed"}>
                                  <Mark />
                                </StateCell>
                              </td>
                            );
                          })}
                        </tr>
                      );
                    })}
                  </Fragment>
                ))}
              </tbody>
            </table>
          </div>
          {sameState == null && <StateLegend items={legend} />}
          {unusual.length > 0 && (
            <ul className="nm-list">
              {unusual.map(({ room, m }) => {
                const Arrow = m.status === "unusual_high" ? ArrowUpIcon : ArrowDownIcon;
                return (
                  <li key={`${room.id}-${m.sensor_type}`}>
                    <Arrow />
                    <span>
                      <b>{room.name}</b> · {metricName(m.sensor_type, t)}{" "}
                      <span className={`pill ${PILL[m.status]}`}>{t(`normal.status.${m.status}`)}</span>{" "}
                      <span className="muted">{detail(m).join(" · ")}</span>
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </>
      )}
    </Card>
  );
}
