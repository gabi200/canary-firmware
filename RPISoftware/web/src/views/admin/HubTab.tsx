/**
 * Hub: the Pis behind this hub (GET /cluster, every 10 s). One Pi runs every role; with three Pis
 * each has a home role (processing, web = the hub address, ai) and takes over a failed Pi's role.
 * On top the mode and plain-language status lines, then one card per Pi: up / down, last seen,
 * the roles it runs now (marked when taken over from another Pi) and its AI HAT+ 2.
 */
import { useCluster } from "../../api/hooks";
import type { ClusterNode, ClusterStatus } from "../../api/types";
import { HubLine } from "../../components/HubStatus";
import { ChipIcon, ServerIcon } from "../../components/Icons";
import { rich, useT } from "../../i18n";
import { piLabel, roleLabel, runnerOf, sortNodes, sortRoles, statusLines, takenOver } from "../../lib/cluster";
import { fmtAgo, fmtClock, fmtDateTime } from "../../lib/time";
import { AdminUnavailable } from "./AdminUnavailable";
import { PiSoftware, SoftwarePanel } from "./SoftwarePanel";

function PiCard({ node, cluster }: { node: ClusterNode; cluster: ClusterStatus }) {
  const { t, lang } = useT();
  const home = node.home_role;
  // its own role runs on another Pi: it is down, or back up and not given its role back yet
  const elsewhere = home && !node.roles.includes(home) ? runnerOf(cluster, home, node) : undefined;
  const hat = node.accelerator;
  // a down Pi cannot vouch for its accelerator
  const hatOn = !!hat?.online && node.alive;

  return (
    <article className={`dev-card hub-card ${node.alive ? "" : "conn-offline"}`}>
      <div className="dev-head">
        <span className="dev-kind" aria-hidden="true">
          <ServerIcon />
        </span>
        <div className="dev-title">
          <div className="dev-name">{cluster.mode === "triple" ? piLabel(node.name, t) : t("hub.singleTitle")}</div>
          {node.ip && <div className="dev-room mono">{node.ip}</div>}
        </div>
        <span className={`dev-conn ${node.alive ? "online" : "offline"}`}>
          <span className="dot" aria-hidden="true" />
          {t(node.alive ? "hub.up" : "hub.down")}
        </span>
      </div>
      <dl className="dev-facts">
        <div>
          <dt>{t("devs.lastSeen")}</dt>
          <dd title={node.last_seen ? fmtDateTime(node.last_seen, lang) : undefined}>{fmtAgo(node.last_seen, lang)}</dd>
        </div>
        <div className="wide">
          <dt>{t("hub.runsNow")}</dt>
          <dd>
            {node.roles.length === 0 ? (
              <span className="muted">{t(node.alive ? "hub.standby" : "hub.runsNothing")}</span>
            ) : (
              <ul className="hub-roles">
                {sortRoles(node.roles).map((r) => (
                  <li key={r} className={`env-chip ${takenOver(node, r) ? "lvl-attention" : ""}`}>
                    {roleLabel(r, t)}
                    {takenOver(node, r) && ` · ${t("hub.takenOver")}`}
                  </li>
                ))}
              </ul>
            )}
          </dd>
        </div>
      </dl>
      {hat && (
        <div className={`hub-accel ${hatOn ? "t-ok" : "t-attention"}`}>
          <ChipIcon />
          {hatOn ? (hat.model ? t("hub.hatOnline", { model: hat.model }) : t("hub.hatOnlinePlain")) : t("hub.hatOff")}
        </div>
      )}
      {node.clock_skew_s != null && Math.abs(node.clock_skew_s) > 2 && (
        <div className="hub-note small t-attention">{t("hub.clockOff", { s: node.clock_skew_s.toFixed(1) })}</div>
      )}
      {elsewhere && <div className="hub-note small t-attention">{t("hub.homeElsewhere", { pi: piLabel(elsewhere.name, t) })}</div>}
      <PiSoftware name={node.name} />
    </article>
  );
}

export function HubTab() {
  const { t, lang } = useT();
  const cluster = useCluster();
  const c = cluster.data;
  if (cluster.isError && !c) return <AdminUnavailable error={cluster.error} />;
  if (!c) return <div className="muted">{t("common.loading")}</div>;
  const triple = c.mode === "triple";
  const lines = statusLines(c, t);

  return (
    <>
      <div className="card hub-mode">
        <ServerIcon />
        <div>
          <div className="hub-mode-title">{triple ? t("hub.modeTriple") : t("hub.modeSingle")}</div>
          {triple && c.vip && (
            <>
              <div>{rich(t("hub.vip"), { ip: <b className="mono">{c.vip}</b> })}</div>
              <div className="muted small">{t("hub.vipHint")}</div>
            </>
          )}
          <div className="muted small">{t("hub.updated", { time: fmtClock(cluster.dataUpdatedAt, lang) })}</div>
          {cluster.isError && (
            <div className="err">{t("hub.refreshFailed", { msg: (cluster.error as Error)?.message ?? "" })}</div>
          )}
        </div>
      </div>
      {lines.length > 0 && (
        <ul className="hub-lines" aria-live="polite">
          {lines.map((l) => (
            <HubLine key={`${l.tone}|${l.text}`} line={l} />
          ))}
        </ul>
      )}
      <SoftwarePanel />
      <div className="dev-grid">
        {sortNodes(c.nodes).map((n) => (
          <PiCard key={n.name} node={n} cluster={c} />
        ))}
      </div>
    </>
  );
}
