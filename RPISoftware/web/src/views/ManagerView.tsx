import {
  useBuilding,
  useDevices,
  useIncidents,
  useOccupancy,
  usePostTelemetry,
  useReadings,
  useResidents,
  useRoster,
  useZones,
} from "../api/hooks";
import { Card } from "../components/Card";
import { FloorPlan } from "../components/FloorPlan";
import { IncidentActions } from "../components/IncidentActions";
import { ResidentList, ResidentRoster } from "../components/ResidentRoster";
import { HazardTriangle, RunningManExit } from "../components/SafetySigns";
import { SignalBadge } from "../components/SignalBadge";
import { StatusPill } from "../components/StatusPill";
import { TrendChart } from "../components/TrendChart";
import { config } from "../config";
import { latestByDevice } from "../lib/latest";
import { buildZoneNames, zoneLabel } from "../lib/labels";

const CLOSED = new Set(["resolution", "false_alarm", "normal"]);

export function ManagerView() {
  const building = useBuilding();
  const zones = useZones();
  const devices = useDevices();
  const allReadings = useReadings(undefined, 400);
  const gas = useReadings("combustible_gas", 200);
  const co = useReadings("co", 200);
  const incidents = useIncidents(false);
  const occupancy = useOccupancy();
  const telemetry = usePostTelemetry();

  const latest = latestByDevice(allReadings.data);
  const active = (incidents.data ?? []).filter((i) => !CLOSED.has(i.state));
  const primary = active[0] ?? null;

  const residents = useResidents();
  const roster = useRoster(primary?.id ?? null);
  const zoneNames = buildZoneNames(zones.data);

  const occByZone: Record<string, number> = {};
  for (const z of occupancy.data?.zones ?? []) occByZone[z.zone_id] = z.persons_est;

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
      {primary?.state === "evacuation" && (
        <div className="sitrep evac" style={{ marginBottom: 16 }}>
          <div className="sitrep-head">
            <RunningManExit size={52} className="safety-sign pulse" title="Evacuate now" />
            <HazardTriangle size={46} className="safety-sign flash" hazard={primary.hazard_type} />
            <div>
              <h2>EVACUATE NOW</h2>
              <div className="sub">
                {primary.hazard_type.replace(/_/g, " ")} · {zoneLabel(zoneNames, primary.primary_zone_id)}
              </div>
            </div>
          </div>
        </div>
      )}

      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 16 }}>
        <h2 style={{ margin: 0 }}>{building.data?.name ?? building.data?.id ?? "Building"}</h2>
        <span className="muted">{building.data?.address}</span>
        <div className="spacer" style={{ flex: 1 }} />
        <StatusPill state={primary?.state ?? "normal"} label={primary ? undefined : "all clear"} />
      </div>

      <div className="grid cols-2">
        <Card title="Floor plan — live sensor status">
          <FloorPlan
            zones={zones.data ?? []}
            devices={devices.data ?? []}
            latest={latest}
            incident={primary}
            occupancyByZone={occByZone}
          />
        </Card>

        <div className="grid" style={{ gap: 16 }}>
          <Card title="Active incidents">
            {active.length === 0 ? (
              <div className="muted">No active incidents.</div>
            ) : (
              active.map((inc) => (
                <div key={inc.id} style={{ marginBottom: 14 }}>
                  <div className="row">
                    <HazardTriangle size={34} className="safety-sign" hazard={inc.hazard_type} />
                    <StatusPill state={inc.state} />
                    <div className="grow">
                      <div>
                        {inc.hazard_type.replace(/_/g, " ")}
                        {inc.advisory && <span className="pill detection" style={{ marginLeft: 8 }}>advisory</span>}
                      </div>
                      <div className="muted small">{zoneLabel(zoneNames, inc.primary_zone_id)}</div>
                    </div>
                    <SignalBadge cls={inc.false_alarm_class} />
                  </div>
                  <IncidentActions incident={inc} />
                </div>
              ))
            )}
          </Card>

          <Card title={primary ? "Residents — live status" : "Residents"}>
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

          <Card title="Device health">
            {(devices.data ?? []).map((d) => (
              <div className="row" key={d.id}>
                <div className="grow">
                  <div className="small">{d.id}</div>
                  <div className="muted small">
                    {d.sensor_type} · fw {d.fw_version}
                  </div>
                </div>
                <span className={`pill ${d.status === "ok" ? "normal" : "alarm"}`}>{d.status}</span>
              </div>
            ))}
          </Card>
        </div>
      </div>

      <div className="grid cols-2" style={{ marginTop: 16 }}>
        <Card title="Combustible gas (ppm)">
          <TrendChart readings={gas.data ?? []} />
        </Card>
        <Card title="Carbon monoxide (ppm)">
          <TrendChart readings={co.data ?? []} />
        </Card>
      </div>

      <Card title="Demo" className="" >
        <div className="row">
          <div className="grow muted small">
            Inject a critical kitchen gas reading through the live pipeline (same path as MQTT).
          </div>
          <button className="btn danger" disabled={telemetry.isPending} onClick={triggerGasLeak}>
            Simulate gas leak
          </button>
        </div>
      </Card>
    </>
  );
}
