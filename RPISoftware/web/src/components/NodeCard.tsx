import { useUpdateNode } from "../api/hooks";
import type { NodeOut, Zone } from "../api/types";
import { useT } from "../i18n";
import { kindLabel, zoneLabel } from "../lib/labels";
import { connectivity, pick, pickNum } from "../lib/nodes";
import { fmtAgo, fmtDateTime, fmtDuration } from "../lib/time";
import { NodeAnalysisView } from "./Analysis";
import { NodeCommands } from "./NodeCommands";
import { NodeMonitor } from "./NodeMonitor";
import { RawStatus } from "./RawStatus";
import { StatusPill } from "./StatusPill";

interface Props {
  node: NodeOut;
  zones: Zone[];
  zoneNames: Map<string, string>;
  /** PATCH /nodes/{id} is limited to managers and admins. */
  canEdit: boolean;
  /** dispatchers do not see presence (radar) data */
  showPresence?: boolean;
}

/** One physical device: identity + connectivity, then its raw status next to the hub's
 *  analysis of it, then raw history charts. */
export function NodeCard({ node, zones, zoneNames, canEdit, showPresence = true }: Props) {
  const { t, lang } = useT();
  const update = useUpdateNode();
  const conn = connectivity(node);
  const doc = node.status;
  const firmware = node.firmware ?? pick(doc, "device.firmware");
  const uptime = pickNum(doc, "uptime_ms");
  const rssi = pickNum(doc, "wifi.rssi");
  // show the requested zone while the PATCH is in flight
  const zoneId = (update.isPending ? update.variables?.patch.zone_id : undefined) ?? node.zone_id;
  const knownZone = zones.some((z) => z.id === zoneId);

  return (
    <div className="card node-card">
      <div className="node-head">
        <span className="node-name">{node.name}</span>
        <span className="tag">{kindLabel(node.kind, t)}</span>
        <StatusPill state={conn.level} label={t(`conn.${conn.state}`)} />
        <span className="spacer" />
        <label className="zone-picker">
          {t("node.zone")}
          {canEdit ? (
            <select
              value={zoneId ?? ""}
              disabled={update.isPending || zones.length === 0}
              onChange={(e) => update.mutate({ nodeId: node.id, patch: { zone_id: e.target.value } })}
            >
              {!knownZone && <option value={zoneId ?? ""}>{zoneLabel(zoneNames, zoneId)}</option>}
              {zones.map((z) => (
                <option key={z.id} value={z.id}>
                  {zoneLabel(zoneNames, z.id)}
                </option>
              ))}
            </select>
          ) : (
            <b>{zoneLabel(zoneNames, zoneId)}</b>
          )}
        </label>
      </div>

      <div className="node-meta">
        <span>
          {t("node.firmware")} <b>{typeof firmware === "string" ? firmware : "—"}</b>
        </span>
        <span title={node.last_seen_ts ? fmtDateTime(node.last_seen_ts, lang) : undefined}>
          {t("node.lastSeen")} <b>{fmtAgo(node.last_seen_ts, lang)}</b>
        </span>
        <span>
          {t("node.uptime")} <b>{uptime != null ? fmtDuration(uptime, lang) : "—"}</b>
        </span>
        <span>
          {t("node.wifi")} <b className={rssi != null && rssi < -80 ? "t-attention" : ""}>
            {rssi != null ? `${rssi} dBm` : "—"}
          </b>
        </span>
        <span>
          {t("node.mqttBase")} <b>{node.mqtt_base}</b>
        </span>
        <span>
          {t("node.boot")} <b>#{node.boot_epoch}</b>
        </span>
      </div>
      {update.isError && (
        <div className="err">{t("node.moveFailed", { msg: (update.error as Error).message })}</div>
      )}

      {/* hardware test (managers / admins; renders nothing for other roles) */}
      <NodeCommands node={node} variant="compact" />

      <NodeMonitor node={node} showPresence={showPresence} />

      <div className="node-body">
        <section>
          <div className="panel-label">{t("node.rawLatest")}</div>
          {conn.state !== "online" && doc && (
            <div className="muted small raw-note">
              {conn.state === "offline" ? t("node.lastReportOffline") : t("node.lastReportStale")}
            </div>
          )}
          <RawStatus kind={node.kind} doc={doc} showPresence={showPresence} />
        </section>
        <section className="analysis-panel">
          <div className="panel-label">{t("common.analysis")}</div>
          {node.analysis ? (
            <NodeAnalysisView analysis={node.analysis} />
          ) : (
            <div className="muted small">{t("node.noAnalysis")}</div>
          )}
        </section>
      </div>
    </div>
  );
}
