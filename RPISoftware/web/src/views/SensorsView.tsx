import { useNodes, useSummary, useZones } from "../api/hooks";
import { ApiError } from "../api/client";
import { useAuth } from "../auth/AuthContext";
import { BuildingBanner, ZoneCard } from "../components/Analysis";
import { Card } from "../components/Card";
import { NodeCard } from "../components/NodeCard";
import { buildZoneNames } from "../lib/labels";

function Unavailable({ what, error }: { what: string; error: unknown }) {
  const status = error instanceof ApiError ? error.status : undefined;
  return (
    <Card>
      <div className="err">
        {what} unavailable{status ? ` (HTTP ${status})` : ""}: {(error as Error).message}
      </div>
      {status === 404 && (
        <div className="muted small">
          This backend does not serve the hardware API yet (docs/HARDWARE.md).
        </div>
      )}
    </Card>
  );
}

/** Hardware sensors: the hub's analysis on top, then every physical device with its raw
 *  status document, analysis and raw history. */
export function SensorsView() {
  const { session } = useAuth();
  const summary = useSummary();
  const nodes = useNodes();
  const zones = useZones();
  const zoneNames = buildZoneNames(zones.data);
  const canEdit = session?.role === "hoa_manager" || session?.role === "system_admin";
  const sorted = [...(nodes.data ?? [])].sort(
    (a, b) => (a.name || a.id).localeCompare(b.name || b.id) || a.id.localeCompare(b.id),
  );

  return (
    <>
      <div className="page-head">
        <h2>Sensors</h2>
        <span className="muted">Hardware nodes — hub analysis and raw device data</span>
      </div>

      <div className="section-title">Analysis</div>
      {summary.isError && !summary.data ? (
        <Unavailable what="Sensor analysis" error={summary.error} />
      ) : !summary.data ? (
        <div className="muted small">Loading analysis…</div>
      ) : (
        <>
          <BuildingBanner summary={summary.data} />
          {(summary.data.zones ?? []).length === 0 ? (
            <div className="muted small">No zone has a sensor node yet.</div>
          ) : (
            <div className="grid zone-grid">
              {summary.data.zones.map((z) => (
                <ZoneCard key={z.zone_id} zone={z} />
              ))}
            </div>
          )}
        </>
      )}

      <div className="section-title">Devices — raw data and analysis</div>
      {nodes.isError && !nodes.data ? (
        <Unavailable what="Sensor nodes" error={nodes.error} />
      ) : !nodes.data ? (
        <div className="muted small">Loading devices…</div>
      ) : sorted.length === 0 ? (
        <Card>
          <div className="muted">
            No hardware nodes yet. A device registers itself on its first MQTT status document
            (<code>&lt;base&gt;/status</code>).
          </div>
        </Card>
      ) : (
        <div className="grid">
          {sorted.map((n) => (
            <NodeCard
              key={n.id}
              node={n}
              zones={zones.data ?? []}
              zoneNames={zoneNames}
              canEdit={canEdit}
            />
          ))}
        </div>
      )}
    </>
  );
}
