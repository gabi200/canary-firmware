import { useNodes, useSensorTrust, useSummary, useZones } from "../api/hooks";
import { ApiError } from "../api/client";
import { useAuth } from "../auth/AuthContext";
import { BuildingBanner, ZoneCard } from "../components/Analysis";
import { Card } from "../components/Card";
import { NodeCard } from "../components/NodeCard";
import { ScopeBar } from "../components/ScopeBar";
import { pluralCategory, rich, useT } from "../i18n";
import { fmtNumber, natural } from "../lib/format";
import { buildZoneNames } from "../lib/labels";
import { useScope } from "../lib/scope";

/** `what` is an already translated "… unavailable" phrase. */
function Unavailable({ what, error }: { what: string; error: unknown }) {
  const { t } = useT();
  const status = error instanceof ApiError ? error.status : undefined;
  return (
    <Card>
      <div className="err">
        {what}
        {status ? ` (HTTP ${status})` : ""}: {(error as Error).message}
      </div>
      {status === 404 && <div className="muted small">{t("sensors.noHardwareApi")}</div>}
    </Card>
  );
}

/** Hardware sensors of the chosen apartment / room (scope bar on top): the building's analysis
 *  banner, the rooms' analysis, then every physical device with its raw status document,
 *  analysis and raw history. */
export function SensorsView() {
  const { t, lang } = useT();
  const { session } = useAuth();
  const summary = useSummary();
  const nodes = useNodes();
  const trust = useSensorTrust(session?.role !== "system_admin");
  const zones = useZones();
  const sc = useScope();
  const zoneNames = buildZoneNames(zones.data);
  const trustByNode = new Map((trust.data ?? []).map((item) => [item.node_id, item]));
  const trustStatus = session?.role === "system_admin" || trust.isError
    ? "unavailable"
    : trust.data
      ? "ready"
      : "loading";
  const canEdit = session?.role === "hoa_manager" || session?.role === "system_admin" || session?.role === "technician";
  // dispatchers get no raw presence (radar) data from the backend: don't ask, don't show
  const showPresence = session?.role !== "dispatcher_external";
  // rooms in the scope bar's order (apartment by apartment), sensors by name inside a room
  const order = new Map(sc.rooms.map((r, i) => [r.id, i]));
  const rank = (zoneId: string) => order.get(zoneId) ?? sc.rooms.length;
  const sorted = (nodes.data ?? [])
    .filter((n) => sc.includes(n.zone_id))
    .sort((a, b) => rank(a.zone_id) - rank(b.zone_id) || natural(a.name || a.id, b.name || b.id) || a.id.localeCompare(b.id));
  const zoneCards = (summary.data?.zones ?? [])
    .filter((z) => sc.includes(z.zone_id))
    .sort((a, b) => rank(a.zone_id) - rank(b.zone_id));
  const count = nodes.data ? t(`rooms.sensorCount.${pluralCategory(lang, sorted.length)}`, { n: fmtNumber(sorted.length, lang, 0) }) : null;
  const empty = <div className="muted small">{t("scope.noSensors", { scope: sc.title })}</div>;

  return (
    <>
      <ScopeBar />
      <div className="page-head">
        <h2>{t("nav.sensors")}</h2>
        <span className="muted">{t("sensors.subtitle")}</span>
      </div>

      <div className="section-title">{t("common.analysis")}</div>
      {summary.isError && !summary.data ? (
        <Unavailable what={t("sensors.analysisUnavailable")} error={summary.error} />
      ) : !summary.data || !sc.ready ? (
        <div className="muted small">{t("sensors.loadingAnalysis")}</div>
      ) : (
        <>
          <BuildingBanner summary={summary.data} />
          <h3 className="scope-heading">{count ? t("scope.heading", { scope: sc.title, sensors: count }) : sc.title}</h3>
          {(summary.data.zones ?? []).length === 0 ? (
            <div className="muted small">{t("sensors.noZones")}</div>
          ) : zoneCards.length === 0 ? (
            empty
          ) : (
            <div className="grid zone-grid">
              {zoneCards.map((z) => (
                // a whole apartment: its rooms' own names; the building: "Bucătărie · Ap. 12"
                <ZoneCard key={z.zone_id} zone={z} name={sc.unit ? undefined : zoneNames.get(z.zone_id)} />
              ))}
            </div>
          )}
        </>
      )}

      <div className="section-title">{t("sensors.devices")}</div>
      {nodes.isError && !nodes.data ? (
        <Unavailable what={t("sensors.nodesUnavailable")} error={nodes.error} />
      ) : !nodes.data || !sc.ready ? (
        <div className="muted small">{t("sensors.loadingDevices")}</div>
      ) : nodes.data.length === 0 ? (
        <Card>
          <div className="muted">
            {rich(t("sensors.noNodes"), { topic: <code>&lt;base&gt;/status</code> })}
          </div>
        </Card>
      ) : sorted.length === 0 ? (
        empty
      ) : (
        <div className="grid">
          {sorted.map((n) => (
            <NodeCard
              key={n.id}
              node={n}
              zones={zones.data ?? []}
              zoneNames={zoneNames}
              canEdit={canEdit}
              showPresence={showPresence}
              trust={trustByNode.get(n.id)}
              trustStatus={trustStatus}
            />
          ))}
        </div>
      )}
    </>
  );
}
