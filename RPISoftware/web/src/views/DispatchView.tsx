import {
  useAccounting,
  useDevices,
  useEvacuation,
  useIncidentEvents,
  useIncidents,
  useReadings,
  useRoster,
  useTriangulation,
  useZones,
} from "../api/hooks";
import { Card } from "../components/Card";
import { FloorPlan } from "../components/FloorPlan";
import { IncidentActions } from "../components/IncidentActions";
import { IncidentTimeline } from "../components/IncidentTimeline";
import { ResidentRoster } from "../components/ResidentRoster";
import { AssemblyPoint, HazardTriangle, RunningManExit } from "../components/SafetySigns";
import { SignalBadge } from "../components/SignalBadge";
import { SignatureBadge } from "../components/SignatureBadge";
import { StatusPill } from "../components/StatusPill";
import { latestByDevice } from "../lib/latest";
import { buildZoneNames, hazardLabel, zoneLabel } from "../lib/labels";
import { parseTs } from "../lib/time";

const STATE_COLOR: Record<string, string> = {
  evacuation: "#b62324",
  alarm: "#f85149",
  escalation: "#f85149",
  detection: "#d29922",
  verification: "#d29922",
};

export function DispatchView() {
  const incidents = useIncidents(true);
  const incident = (incidents.data ?? [])[0] ?? null;
  const accounting = useAccounting(incident?.id ?? null);
  const events = useIncidentEvents(incident?.id ?? null);
  const triangulation = useTriangulation(incident?.id ?? null);
  const roster = useRoster(incident?.id ?? null);
  const zones = useZones();
  const devices = useDevices();
  const readings = useReadings(undefined, 400);
  const evacuation = useEvacuation();
  const latest = latestByDevice(readings.data);
  const zoneNames = buildZoneNames(zones.data);

  if (!incident) {
    return (
      <Card>
        <div className="metric good" style={{ padding: 24 }}>
          <div className="n">All clear</div>
          <div className="l">No active incidents in this building</div>
        </div>
      </Card>
    );
  }

  const acc = accounting.data;
  const occByZone: Record<string, number> = {};
  for (const z of acc?.zones_with_people ?? []) occByZone[z.zone_id] = z.persons_est;
  const total = acc?.occupancy_total ?? 0;
  const accounted = acc?.accounted ?? 0;
  const pct = total > 0 ? Math.round((accounted / total) * 100) : 100;
  const banner = STATE_COLOR[incident.state] ?? "#1565c0";

  return (
    <>
      <div className={`sitrep ${incident.state === "evacuation" ? "evac" : ""}`} style={{ background: banner, marginBottom: 16 }}>
        <div className="sitrep-head">
          {incident.state === "evacuation" && (
            <RunningManExit size={58} className="safety-sign pulse" title="Evacuate now" />
          )}
          <HazardTriangle
            size={52}
            className={`safety-sign ${incident.state === "evacuation" ? "flash" : ""}`}
            hazard={incident.hazard_type}
            title={hazardLabel(incident.hazard_type)}
          />
          <div>
            <h2>
              {incident.state === "evacuation"
                ? "EVACUATE NOW"
                : hazardLabel(incident.hazard_type)}
            </h2>
            <div className="sub">
              {hazardLabel(incident.hazard_type)} · source{" "}
              {zoneLabel(zoneNames, incident.primary_zone_id)} · opened{" "}
              {new Date(parseTs(incident.opened_ts)).toLocaleTimeString()}
            </div>
          </div>
        </div>
        <div style={{ marginTop: 10 }}>
          <SignalBadge cls={incident.false_alarm_class} />
          <SignatureBadge signature={incident.signature} />
        </div>
      </div>

      <div className="grid cols-3" style={{ marginBottom: 16 }}>
        <Card>
          <div className="metric">
            <div className="n">{Math.round(total)}</div>
            <div className="l">Occupants (est.)</div>
          </div>
        </Card>
        <Card>
          <div className="metric good">
            <div className="n">{accounted}</div>
            <div className="l">Accounted for</div>
          </div>
        </Card>
        <Card>
          <div className={`metric ${(acc?.unaccounted ?? 0) > 0 ? "danger" : "good"}`}>
            <div className="n">{acc?.unaccounted ?? 0}</div>
            <div className="l">Unaccounted</div>
          </div>
        </Card>
      </div>

      <div className="grid cols-2">
        <Card title="Hazard localization">
          <FloorPlan
            zones={zones.data ?? []}
            devices={devices.data ?? []}
            latest={latest}
            incident={incident}
            occupancyByZone={occByZone}
          />
        </Card>

        <div className="grid" style={{ gap: 16 }}>
          <Card title="Hazard source (AI triangulation)">
            {triangulation.data && triangulation.data.source_zone_id ? (
              <>
                <div className="row">
                  <div className="grow">
                    <div style={{ fontSize: 18, fontWeight: 700 }}>{zoneLabel(zoneNames, triangulation.data.source_zone_id)}</div>
                    <div className="muted small">{triangulation.data.method}</div>
                  </div>
                  <span className={`pill ${triangulation.data.confidence >= 0.6 ? "alarm" : "detection"}`}>
                    {Math.round(triangulation.data.confidence * 100)}% conf
                  </span>
                </div>
                <div className="muted small" style={{ marginTop: 6 }}>
                  {triangulation.data.n_contributors} sensor(s)
                  {incident.primary_zone_id !== triangulation.data.source_zone_id
                    ? ` · first detected in ${zoneLabel(zoneNames, incident.primary_zone_id)}`
                    : ""}
                </div>
                {triangulation.data.contributors.slice(0, 3).map((c) => (
                  <div className="row" key={c.device_id}>
                    <div className="grow small">{zoneLabel(zoneNames, c.zone_id)}</div>
                    <div className="muted small">
                      {c.value} · w{c.weight.toFixed(2)}
                    </div>
                  </div>
                ))}
                <div className="muted small" style={{ marginTop: 6 }}>
                  Estimate — indoor triangulation is approximate (diffusion/HVAC). Verify on site.
                </div>
              </>
            ) : (
              <div className="muted small">Awaiting corroborating sensors…</div>
            )}
          </Card>

          <Card title="Evacuation progress">
            <div className="progress">
              <div style={{ width: `${pct}%` }} />
            </div>
            <div className="muted small" style={{ marginTop: 8 }}>
              {accounted}/{Math.round(total)} accounted ({pct}%) · {acc?.needs_help ?? 0} need help
            </div>
            <div style={{ marginTop: 12 }}>
              <IncidentActions incident={incident} />
            </div>
            {evacuation.data?.assembly_points?.[0] && (
              <div className="assembly-row">
                <AssemblyPoint size={40} className="safety-sign" />
                <div className="small">
                  <div className="muted">Proceed to assembly point</div>
                  <div style={{ fontWeight: 700 }}>{evacuation.data.assembly_points[0].label}</div>
                </div>
              </div>
            )}
          </Card>

          <Card title="Resident accountability">
            {roster.data ? (
              <ResidentRoster roster={roster.data} />
            ) : (
              <div className="muted small">Loading resident roster…</div>
            )}
          </Card>

          <Card title="Last-known occupied zones">
            {(acc?.zones_with_people ?? []).length === 0 ? (
              <div className="muted small">No occupancy detected.</div>
            ) : (
              (acc?.zones_with_people ?? []).map((z) => (
                <div className="row" key={z.zone_id}>
                  <div className="grow">{zoneLabel(zoneNames, z.zone_id)}</div>
                  <span className="pill detection">{z.persons_est} ppl</span>
                </div>
              ))
            )}
          </Card>

          <Card title="Incident timeline">
            <div style={{ marginBottom: 8 }}>
              <StatusPill state={incident.state} />
            </div>
            <IncidentTimeline events={events.data ?? []} />
          </Card>
        </div>
      </div>
    </>
  );
}
