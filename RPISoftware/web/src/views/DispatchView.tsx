import {
  useAccounting,
  useEvacuation,
  useIncidentEvents,
  useIncidents,
  useRoster,
  useTriangulation,
  useZones,
} from "../api/hooks";
import { Card } from "../components/Card";
import { EscalationLine } from "../components/EscalationLine";
import { FusionExplanationPanel } from "../components/FusionExplanation";
import { HazardMap } from "../components/HazardMap";
import { IncidentActions } from "../components/IncidentActions";
import { IncidentBanner } from "../components/IncidentBanner";
import { IncidentBriefCard } from "../components/IncidentBrief";
import { WaterImpactCard } from "../components/WaterImpactCard";
import { IncidentTimeline } from "../components/IncidentTimeline";
import { OccupiedZonesCard } from "../components/OccupiedZonesCard";
import { PriorityAlert, PriorityPanel, priorityAwaiting } from "../components/PriorityPanel";
import { ResidentRoster } from "../components/ResidentRoster";
import { SafetySign } from "../components/SafetySigns";
import { SignalBadge } from "../components/SignalBadge";
import { SignatureBadge } from "../components/SignatureBadge";
import { StatusPill } from "../components/StatusPill";
import { useT } from "../i18n";
import { fmtNumber } from "../lib/format";
import { buildZoneNames, hazardLabel, triangulationMethodLabel, zoneLabel } from "../lib/labels";
import { fmtClock } from "../lib/time";

export function DispatchView() {
  const { t, lang } = useT();
  const incidents = useIncidents(true);
  const incident = (incidents.data ?? [])[0] ?? null;
  const accounting = useAccounting(incident?.id ?? null);
  const events = useIncidentEvents(incident?.id ?? null);
  const triangulation = useTriangulation(incident?.id ?? null);
  const roster = useRoster(incident?.id ?? null);
  const zones = useZones();
  const evacuation = useEvacuation();
  const zoneNames = buildZoneNames(zones.data);

  if (!incident) {
    return (
      <Card>
        <div className="metric good" style={{ padding: 24 }}>
          <div className="n">{t("common.allClear")}</div>
          <div className="l">{t("dispatch.noActive")}</div>
        </div>
      </Card>
    );
  }

  const acc = accounting.data;
  const total = acc?.occupancy_total ?? 0;
  const accounted = acc?.accounted ?? 0;
  const pct = total > 0 ? Math.round((accounted / total) * 100) : 100;
  const hazard = hazardLabel(incident.hazard_type, t);
  // care profiles: only ever sent for an active incident (this view shows active ones only)
  const priority = roster.data?.priority ?? [];
  const prioAwaiting = priorityAwaiting(roster.data, acc?.priority_awaiting);

  return (
    <>
      <IncidentBanner
        state={incident.state}
        hazardType={incident.hazard_type}
        hazardTitle={hazard}
        headline={incident.state === "evacuation" ? t("evac.now") : hazard}
        sub={t("dispatch.sub", {
          hazard,
          zone: zoneLabel(zoneNames, incident.primary_zone_id),
          time: fmtClock(incident.opened_ts, lang),
        })}
        tags={
          <>
            <SignalBadge cls={incident.false_alarm_class} />
            <SignatureBadge signature={incident.signature} />
          </>
        }
        status={
          <>
            <PriorityAlert count={prioAwaiting} />
            <EscalationLine incidentId={incident.id} onDark />
          </>
        }
        advice
      />

      <PriorityPanel people={priority} />

      <div className="grid cols-3 metric-row" style={{ marginBottom: 16 }}>
        <Card>
          <div className="metric">
            <div className="n">{Math.round(total)}</div>
            <div className="l">{t("dispatch.occupants")}</div>
          </div>
        </Card>
        <Card>
          <div className={`metric ${total > 0 ? "good" : ""}`}>
            <div className="n">{accounted}</div>
            <div className="l">{t("dispatch.accounted")}</div>
          </div>
        </Card>
        <Card>
          <div className={`metric ${(acc?.unaccounted ?? 0) > 0 ? "danger" : total > 0 ? "good" : ""}`}>
            <div className="n">{acc?.unaccounted ?? 0}</div>
            <div className="l">{t("dispatch.unaccounted")}</div>
          </div>
        </Card>
      </div>

      <div className="grid cols-2">
        <Card title={t("dispatch.localization")}>
          <HazardMap incident={incident} />
        </Card>

        <div className="grid dispatch-side" style={{ gap: 16 }}>
          <Card title={t("dispatch.progress")} className="dispatch-actions">
            <div className={`progress ${total > 0 ? "" : "idle"}`}>
              <div style={{ width: `${pct}%` }} />
            </div>
            <div className="muted small" style={{ marginTop: 8 }}>
              {t("dispatch.progressLine", {
                accounted,
                total: Math.round(total),
                pct,
                help: acc?.needs_help ?? 0,
              })}
            </div>
            <PriorityAlert count={prioAwaiting} />
            <div style={{ marginTop: 12 }}>
              <IncidentActions incident={incident} />
            </div>
            {evacuation.data?.assembly_points?.[0] && (
              <div className="assembly-row">
                <SafetySign code="E007" size={40} className="safety-sign" />
                <div className="small">
                  <div className="muted">{t("dispatch.assembly")}</div>
                  <div style={{ fontWeight: 700 }}>{evacuation.data.assembly_points[0].label}</div>
                </div>
              </div>
            )}
          </Card>

          <Card title={t("dispatch.accountability")} className="dispatch-roster">
            {roster.data ? (
              <ResidentRoster roster={roster.data} />
            ) : (
              <div className="muted small">{t("dispatch.loadingRoster")}</div>
            )}
          </Card>

          <Card title={t("dispatch.source")}>
            {triangulation.data && triangulation.data.source_zone_id ? (
              <>
                <div className="row">
                  <div className="grow">
                    <div style={{ fontSize: 18, fontWeight: 700 }}>{zoneLabel(zoneNames, triangulation.data.source_zone_id)}</div>
                    <div className="muted small">{triangulationMethodLabel(triangulation.data.method, t)}</div>
                  </div>
                  <span className={`pill ${triangulation.data.confidence >= 0.6 ? "alarm" : "detection"}`}>
                    {t("dispatch.confidence", { pct: Math.round(triangulation.data.confidence * 100) })}
                  </span>
                </div>
                <div className="muted small" style={{ marginTop: 6 }}>
                  {t("dispatch.sensors", { n: triangulation.data.n_contributors })}
                  {incident.primary_zone_id !== triangulation.data.source_zone_id
                    ? ` · ${t("dispatch.firstDetected", { zone: zoneLabel(zoneNames, incident.primary_zone_id) })}`
                    : ""}
                </div>
                {triangulation.data.contributors.slice(0, 3).map((c) => (
                  <div className="row" key={c.device_id}>
                    <div className="grow small">{zoneLabel(zoneNames, c.zone_id)}</div>
                    <div className="muted small">
                      {fmtNumber(c.value, lang, 1)} · {t("dispatch.weight", { w: fmtNumber(c.weight, lang, 2, true) })}
                    </div>
                  </div>
                ))}
                <div className="muted small" style={{ marginTop: 6 }}>
                  {t("dispatch.estimateNote")}
                </div>
              </>
            ) : (
              <div className="muted small">{t("dispatch.awaitingSensors")}</div>
            )}
          </Card>

          <FusionExplanationPanel incidentId={incident.id} />

          <IncidentBriefCard incidentId={incident.id} />
          {incident.hazard_type === "water_leak" && <WaterImpactCard incidentId={incident.id} />}

          <OccupiedZonesCard occupied={acc?.zones_with_people ?? []} />

          <Card title={t("dispatch.timeline")}>
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
