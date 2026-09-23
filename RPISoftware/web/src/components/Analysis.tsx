import type { BuildingSummary, Indicator, NodeAnalysis, ZoneSummary } from "../api/types";
import { KIND_LABEL, LEVEL_LABEL } from "../lib/nodes";
import { fmtClock } from "../lib/time";
import { StatusPill } from "./StatusPill";

const TREND_ARROW: Record<string, string> = { rising: "↑", falling: "↓", stable: "→" };

/** Level-coloured indicator rows: label, value (+ detail) and trend. */
export function IndicatorList({ indicators }: { indicators: Indicator[] }) {
  if (indicators.length === 0) return <div className="muted small">No indicators yet.</div>;
  return (
    <div>
      {indicators.map((ind) => (
        <div className="indicator" key={ind.key}>
          <span className={`lvl ${ind.level}`} title={LEVEL_LABEL[ind.level] ?? ind.level} />
          <span className="ind-label">{ind.label}</span>
          <span className={`ind-value t-${ind.level}`}>
            {ind.value}
            {ind.detail && <span className="muted"> · {ind.detail}</span>}
          </span>
          <span className="trend" title={ind.trend ?? undefined}>
            {ind.trend ? TREND_ARROW[ind.trend] : ""}
          </span>
        </div>
      ))}
    </div>
  );
}

/** One node as the hub interprets it: status, headline, indicators, advice. */
export function NodeAnalysisView({ analysis }: { analysis: NodeAnalysis }) {
  return (
    <div>
      <div className="analysis-head">
        <StatusPill state={analysis.status} label={LEVEL_LABEL[analysis.status]} />
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
  return (
    <div className={`env-banner ${summary.status}`}>
      <div className="grow">
        <div className="env-status">{LEVEL_LABEL[summary.status] ?? summary.status}</div>
        <div className="env-headline">{summary.headline}</div>
        <div className="muted small">Analysis updated {fmtClock(summary.generated_ts)}</div>
      </div>
      <div className="metric">
        <div className="n">
          {summary.nodes_online}/{summary.nodes_total}
        </div>
        <div className="l">Nodes online</div>
      </div>
      <div className={`metric ${summary.active_incidents > 0 ? "danger" : ""}`}>
        <div className="n">{summary.active_incidents}</div>
        <div className="l">Active incidents</div>
      </div>
    </div>
  );
}

export function ZoneCard({ zone }: { zone: ZoneSummary }) {
  return (
    <div className="card">
      <div className="zone-head">
        <span className="zone-name">{zone.zone_label}</span>
        {zone.occupied != null && (
          <span className="muted small">{zone.occupied ? "Occupied" : "Empty"}</span>
        )}
        <StatusPill state={zone.status} label={LEVEL_LABEL[zone.status]} />
      </div>
      {zone.nodes.map((n) => (
        <div className="zone-node" key={n.node_id}>
          <div className="zone-node-name">
            {n.name} <span className="tag">{KIND_LABEL[n.kind] ?? n.kind}</span>
            {(!n.online || n.stale) && (
              <span className="muted small">{n.online ? "stale" : "offline"}</span>
            )}
          </div>
          <NodeAnalysisView analysis={n} />
        </div>
      ))}
    </div>
  );
}
