import type { BuildingSummary, Indicator, NodeAnalysis, ZoneSummary } from "../api/types";
import { useT } from "../i18n";
import { kindLabel, levelLabel, tokenLabel } from "../lib/labels";
import { fmtClock } from "../lib/time";
import { StatusPill } from "./StatusPill";

const TREND_ARROW: Record<string, string> = { rising: "↑", falling: "↓", stable: "→" };

/** Level-coloured indicator rows: label, value (+ detail) and trend. Labels, values,
 *  headlines and advice are backend text (localized via Accept-Language). */
export function IndicatorList({ indicators }: { indicators: Indicator[] }) {
  const { t } = useT();
  if (indicators.length === 0) return <div className="muted small">{t("analysis.noIndicators")}</div>;
  return (
    <div>
      {indicators.map((ind) => (
        <div className="indicator" key={ind.key}>
          <span className={`lvl ${ind.level}`} title={levelLabel(ind.level, t)} />
          <span className="ind-label">{ind.label}</span>
          <span className={`ind-value t-${ind.level}`}>
            {ind.value}
            {ind.detail && <span className="muted"> · {ind.detail}</span>}
          </span>
          <span className="trend" title={ind.trend ? tokenLabel(t, "trend", ind.trend) : undefined}>
            {ind.trend ? TREND_ARROW[ind.trend] : ""}
          </span>
        </div>
      ))}
    </div>
  );
}

/** One node as the hub interprets it: status, headline, indicators, advice. */
export function NodeAnalysisView({ analysis }: { analysis: NodeAnalysis }) {
  const { t } = useT();
  return (
    <div>
      <div className="analysis-head">
        <StatusPill state={analysis.status} label={levelLabel(analysis.status, t)} />
        <span className="headline">{analysis.headline}</span>
      </div>
      <IndicatorList indicators={analysis.indicators ?? []} />
      {(analysis.advice ?? []).length > 0 && (
        <ul className="advice">
          {analysis.advice.map((a, i) => (
            <li key={i}>{a}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function BuildingBanner({ summary }: { summary: BuildingSummary }) {
  const { t, lang } = useT();
  return (
    <div className={`env-banner ${summary.status}`}>
      <div className="grow">
        <div className="env-status">{levelLabel(summary.status, t)}</div>
        <div className="env-headline">{summary.headline}</div>
        <div className="muted small">
          {t("analysis.updated", { time: fmtClock(summary.generated_ts, lang) })}
        </div>
      </div>
      <div className="metric">
        <div className="n">
          {summary.nodes_online}/{summary.nodes_total}
        </div>
        <div className="l">{t("analysis.nodesOnline")}</div>
      </div>
      <div className={`metric ${summary.active_incidents > 0 ? "danger" : ""}`}>
        <div className="n">{summary.active_incidents}</div>
        <div className="l">{t("common.activeIncidents")}</div>
      </div>
    </div>
  );
}

/** `name`: the zone's display name ("Bucătărie · Ap. 12" when several rooms share the label). */
export function ZoneCard({ zone, name }: { zone: ZoneSummary; name?: string }) {
  const { t } = useT();
  return (
    <div className="card">
      <div className="zone-head">
        <span className="zone-name">{name ?? zone.zone_label}</span>
        {zone.occupied != null && (
          <span className="muted small">{zone.occupied ? t("zone.occupied") : t("zone.empty")}</span>
        )}
        <StatusPill state={zone.status} label={levelLabel(zone.status, t)} />
      </div>
      {zone.nodes.map((n) => (
        <div className="zone-node" key={n.node_id}>
          <div className="zone-node-name">
            {n.name} <span className="tag">{kindLabel(n.kind, t)}</span>
            {(!n.online || n.stale) && (
              <span className="muted small">{n.online ? t("conn.stale") : t("conn.offline")}</span>
            )}
          </div>
          <NodeAnalysisView analysis={n} />
        </div>
      ))}
    </div>
  );
}
