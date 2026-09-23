import { useUpdateNode } from "../api/hooks";
import type { NodeOut, Zone } from "../api/types";
import { zoneLabel } from "../lib/labels";
import { KIND_LABEL, connectivity, pick, pickNum } from "../lib/nodes";
import { fmtAgo, fmtDuration, parseTs } from "../lib/time";
import { NodeAnalysisView } from "./Analysis";
import { NodeHistoryCharts } from "./NodeHistoryCharts";
import { RawStatus } from "./RawStatus";
import { StatusPill } from "./StatusPill";

interface Props {
  node: NodeOut;
  zones: Zone[];
  zoneNames: Map<string, string>;
  /** PATCH /nodes/{id} is limited to managers and admins. */
  canEdit: boolean;
}

/** One physical device: identity + connectivity, then its raw status next to the hub's
 *  analysis of it, then raw history charts. */
export function NodeCard({ node, zones, zoneNames, canEdit }: Props) {
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
        <span className="tag">{KIND_LABEL[node.kind] ?? node.kind}</span>
        <StatusPill state={conn.level} label={conn.label} />
        <span className="spacer" />
        <label className="zone-picker">
          Zone
          {canEdit ? (
            <select
              value={zoneId ?? ""}
              disabled={update.isPending || zones.length === 0}
              onChange={(e) => update.mutate({ nodeId: node.id, patch: { zone_id: e.target.value } })}
            >
              {!knownZone && <option value={zoneId ?? ""}>{zoneLabel(zoneNames, zoneId)}</option>}
              {zones.map((z) => (
                <option key={z.id} value={z.id}>
                  {z.label || z.id}
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
          firmware <b>{typeof firmware === "string" ? firmware : "—"}</b>
        </span>
        <span
          title={node.last_seen_ts ? new Date(parseTs(node.last_seen_ts)).toLocaleString() : undefined}
        >
          last seen <b>{fmtAgo(node.last_seen_ts)}</b>
        </span>
        <span>
          uptime <b>{uptime != null ? fmtDuration(uptime) : "—"}</b>
        </span>
        <span>
          Wi-Fi <b className={rssi != null && rssi < -80 ? "t-attention" : ""}>
            {rssi != null ? `${rssi} dBm` : "—"}
          </b>
        </span>
        <span>
          MQTT base <b>{node.mqtt_base}</b>
        </span>
        <span>
          boot <b>#{node.boot_epoch}</b>
        </span>
      </div>
      {update.isError && (
        <div className="err">Could not move node: {(update.error as Error).message}</div>
      )}

      <div className="node-body">
        <section>
          <div className="panel-label">Raw · latest status document</div>
          {conn.label !== "online" && doc && (
            <div className="muted small raw-note">
              Device {conn.label} — values are from its last report.
            </div>
          )}
          <RawStatus kind={node.kind} doc={doc} />
        </section>
        <section className="analysis-panel">
          <div className="panel-label">Analysis</div>
          {node.analysis ? (
            <NodeAnalysisView analysis={node.analysis} />
          ) : (
            <div className="muted small">No analysis yet.</div>
          )}
        </section>
      </div>

      <NodeHistoryCharts node={node} />
    </div>
  );
}
