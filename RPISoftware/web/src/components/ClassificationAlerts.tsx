import { useIncidents, useZones } from "../api/hooks";
import { useT } from "../i18n";
import { hasClassificationAlert } from "../lib/classification";
import { buildZoneNames, tokenLabel, zoneLabel } from "../lib/labels";
import { fmtDateTime } from "../lib/time";

const ALARMED = new Set(["alarm", "escalation", "evacuation"]);
const FIRE_OR_GAS = new Set(["smouldering_fire", "flaming_fire", "gas_leak"]);
const pct = (value: number) => Number.isFinite(value) ? `${Math.round(Math.max(0, Math.min(1, value)) * 100)}%` : "—";

export function ClassificationAlerts() {
  const { t, lang } = useT();
  const incidents = useIncidents();
  const zones = useZones();
  const alerts = (incidents.data ?? []).filter(hasClassificationAlert);
  if (!alerts.length) return null;
  const names = buildZoneNames(zones.data);

  return (
    <section className="classification-alerts content" role="status" aria-label={t("classification.title")} tabIndex={0}>
      {alerts.map((incident) => {
        const signature = incident.signature!;
        return (
          <article className={`card classification-alert ${FIRE_OR_GAS.has(signature.label) ? "hazard" : ""}`} key={incident.id}>
            <div className="row">
              <h2>{t("classification.title")}</h2>
              <span className="muted small">{zoneLabel(names, incident.primary_zone_id)}</span>
            </div>
            <div>{t("classification.rules")}: <strong>{tokenLabel(t, "signature", signature.label)}</strong> · {t("classification.confidence", { pct: pct(signature.confidence) })}</div>
            {signature.shadow_label && signature.shadow_confidence !== null && (
              <div className="small">{t("classification.model")}: <b>{tokenLabel(t, "signature", signature.shadow_label)}</b> · {t("classification.confidence", { pct: pct(signature.shadow_confidence) })}</div>
            )}
            {ALARMED.has(incident.state) && <div className="small">{t("classification.alarmInstructions")}</div>}
            <div className="muted small">{t("classification.updated", { time: fmtDateTime(signature.ts, lang) })}</div>
            {signature.evidence.length > 0 && (
              <details>
                <summary>{t("classification.evidence")}</summary>
                <ul>{signature.evidence.map((line, index) => <li key={index}>{line}</li>)}</ul>
              </details>
            )}
          </article>
        );
      })}
    </section>
  );
}
