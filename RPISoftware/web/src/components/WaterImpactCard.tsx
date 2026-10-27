/**
 * The units a water leak may reach, from the building's explicit plumbing plan: below the leak
 * (nearest floor first) and on a shared riser. A missing or broken plan says "unknown", never
 * "none". No volume estimate, no valve action.
 */
import { useWaterImpact } from "../api/hooks";
import type { WaterImpactUnit } from "../api/types";
import { useT } from "../i18n";
import { Card } from "./Card";

export function WaterImpactCard({ incidentId, inline = false }: { incidentId: string; inline?: boolean }) {
  const { t } = useT();
  const impact = useWaterImpact(incidentId);
  const d = impact.data;
  const why = (u: WaterImpactUnit) =>
    u.reason === "below"
      ? u.hops === 1
        ? t("water.below1")
        : t("water.belowN", { n: u.hops ?? 0 })
      : t("water.riser", { riser: u.riser ?? "" });
  const body = (
    <>
      <div className="muted small" style={{ marginBottom: 8 }}>{t("water.caveat")}</div>
      {impact.isError && <div className="muted small">{t("water.unavailable")}</div>}
      {d && d.topology === "not_configured" && <div className="pill unknown">{t("water.notConfigured")}</div>}
      {d && d.topology === "invalid" && <div className="pill attention">{t("water.invalid")}</div>}
      {d && d.topology === "configured" && (
        <>
          {d.leaking_units.length > 0 && (
            <div className="small" style={{ marginBottom: 6 }}>
              {t("water.leaking", { units: d.leaking_units.map((u) => u.label).join(", ") })}
            </div>
          )}
          {d.affected.length === 0 && <div className="muted small">{t("water.none")}</div>}
          {d.affected.map((u) => (
            <div key={u.unit_id} className="row" style={{ marginBottom: 4 }}>
              <div className="grow">{u.label}</div>
              <span className={`pill ${u.reason === "below" && u.hops === 1 ? "attention" : "unknown"}`}>{why(u)}</span>
            </div>
          ))}
        </>
      )}
    </>
  );
  if (d && !d.applicable) return null;
  return inline ? (
    <div style={{ marginTop: 8 }}>
      <div className="panel-label">{t("water.title")}</div>
      {body}
    </div>
  ) : (
    <Card title={t("water.title")}>{body}</Card>
  );
}
