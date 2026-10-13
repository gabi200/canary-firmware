import {
  useBuilding,
  useIncidents,
  usePostTelemetry,
  useReadings,
  useResidents,
  useRoster,
  useZones,
} from "../api/hooks";
import { Card } from "../components/Card";
import { DeviceHealthCard } from "../components/DeviceHealthCard";
import { EnvironmentCard } from "../components/EnvironmentCard";
import { EscalationLine } from "../components/EscalationLine";
import { HazardMap } from "../components/HazardMap";
import { HubBanner } from "../components/HubStatus";
import { IncidentActions } from "../components/IncidentActions";
import { PriorityAlert, PriorityPanel, priorityAwaiting } from "../components/PriorityPanel";
import { ResidentList, ResidentRoster } from "../components/ResidentRoster";
import { SafetySign, hazardSign } from "../components/SafetySigns";
import { SignalBadge } from "../components/SignalBadge";
import { SignatureBadge } from "../components/SignatureBadge";
import { StatusPill } from "../components/StatusPill";
import { ApartmentTrendChart } from "../components/TrendChart";
import { config } from "../config";
import { useT } from "../i18n";
import { buildZoneNames, hazardLabel, zoneLabel } from "../lib/labels";

const CLOSED = new Set(["resolution", "false_alarm", "normal"]);

export function ManagerView() {
  const { t } = useT();
  const building = useBuilding();
  const zones = useZones();
  // one line per apartment: ~10 min of readings from every air node (each reports every 15 s)
  const gas = useReadings("combustible_gas", 600);
  const co = useReadings("co", 600);
  const incidents = useIncidents(false);
  const telemetry = usePostTelemetry();

  const active = (incidents.data ?? []).filter((i) => !CLOSED.has(i.state));
  const primary = active[0] ?? null;

  const residents = useResidents();
  const roster = useRoster(primary?.id ?? null);
  const zoneNames = buildZoneNames(zones.data);
  // care profiles (health data): only for the active primary incident, never otherwise
  const priority = primary ? roster.data?.priority : undefined;
  const prioAwaiting = primary ? priorityAwaiting(roster.data) : 0;


  function triggerGasLeak() {
    telemetry.mutate({
      schema: "canary.telemetry.v1",
      device_id: "dev_gas_kitchen",
      sensor_type: "combustible_gas",
      location: {
        building_id: config.defaultBuildingId,
        floor_id: "flr_03",
        unit_id: "unit_0312",
        zone_id: "zone_kitchen",
      },
      value: 6000,
      units: "ppm",
      edge_state: "alarm",
      epoch: 1,
      seq: Date.now() % 100000,
    });
  }

  return (
    <>
      <HubBanner />
      {primary?.state === "evacuation" && (
        <div className="sitrep evac" style={{ marginBottom: 16 }}>
          <div className="sitrep-head">
            <SafetySign code="E002" size={52} className="safety-sign pulse" title={t("evac.nowTitle")} />
            <SafetySign code={hazardSign(primary.hazard_type)} size={46} className="safety-sign flash" />
            <div>
              <h2>{t("evac.now")}</h2>
              <div className="sub">
                {hazardLabel(primary.hazard_type, t)} · {zoneLabel(zoneNames, primary.primary_zone_id)}
              </div>
            </div>
          </div>
          <PriorityAlert count={prioAwaiting} />
        </div>
      )}

      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 16 }}>
        <h2 style={{ margin: 0 }}>{building.data?.name ?? building.data?.id ?? t("manager.building")}</h2>
        <span className="muted">{building.data?.address}</span>
        <div className="spacer" style={{ flex: 1 }} />
        <StatusPill state={primary?.state ?? "normal"} label={primary ? undefined : t("common.allClear")} />
      </div>

      <PriorityPanel people={priority} />

      {active.length > 0 && (
        <Card title={t("common.activeIncidents")}>
          {active.map((inc) => (
            <div key={inc.id} style={{ marginBottom: 14 }}>
              <div className="row">
                <SafetySign code={hazardSign(inc.hazard_type)} size={34} className="safety-sign" />
                <StatusPill state={inc.state} />
                <div className="grow">
                  <div>
                    {hazardLabel(inc.hazard_type, t)}
                    {inc.advisory && (
                      <span className="pill detection" style={{ marginLeft: 8 }}>
                        {t("manager.advisory")}
                      </span>
                    )}
                  </div>
                  <div className="muted small">{zoneLabel(zoneNames, inc.primary_zone_id)}</div>
                </div>
                <SignalBadge cls={inc.false_alarm_class} />
                <SignatureBadge signature={inc.signature} />
              </div>
              {inc.id === primary?.id && <PriorityAlert count={prioAwaiting} />}
              <EscalationLine incidentId={inc.id} />
              <IncidentActions incident={inc} />
            </div>
          ))}
        </Card>
      )}

      {/* the plan is the page: full width, so every apartment and room stays readable */}
      <Card title={t("manager.floorPlan")} className="plan-card">
        <HazardMap incident={primary} />
      </Card>

      <div className="grid cols-even" style={{ marginTop: 16 }}>
        <EnvironmentCard />
        <DeviceHealthCard />
      </div>

      <div className="grid cols-even" style={{ marginTop: 16 }}>
        <Card title={primary ? t("manager.residentsLive") : t("manager.residents")}>
          {primary && roster.data ? (
            <ResidentRoster roster={roster.data} />
          ) : (
            <ResidentList
              entries={(residents.data ?? []).map((r) => ({
                ...r,
                status: "unknown",
                source: null,
                ts: null,
              }))}
            />
          )}
        </Card>
        <div className="grid" style={{ gap: 16 }}>
          <Card title={t("sensor.combustible_gas")}>
            <div className="muted small trend-caption">{t("env.trendCaption")}</div>
            {gas.data ? <ApartmentTrendChart readings={gas.data} /> : <div className="muted small">{t("common.loading")}</div>}
          </Card>
          <Card title={t("sensor.co")}>
            <div className="muted small trend-caption">{t("env.trendCaption")}</div>
            {co.data ? <ApartmentTrendChart readings={co.data} /> : <div className="muted small">{t("common.loading")}</div>}
          </Card>
        </div>
      </div>

      <Card title={t("manager.demo")} className="">
        <div className="row">
          <div className="grow muted small">{t("manager.demoText")}</div>
          <button className="btn danger" disabled={telemetry.isPending} onClick={triggerGasLeak}>
            {t("manager.simulate")}
          </button>
        </div>
      </Card>
    </>
  );
}
