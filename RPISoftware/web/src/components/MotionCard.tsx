/**
 * Motion per room from the ESPectre Wi-Fi boards (staff only): motion detected / no recent motion /
 * calibrating / unavailable / no presence sensor, with the age of the last motion. Movement only:
 * never a person count, never "empty". Renders nothing for roles the endpoint refuses.
 */
import { useMotion } from "../api/hooks";
import type { MotionState } from "../api/types";
import { useAuth } from "../auth/AuthContext";
import { useT } from "../i18n";
import { canSeeCluster } from "../lib/cluster";
import { fmtAgo } from "../lib/time";
import { Card } from "./Card";

export const MOTION_PILL: Record<MotionState, string> = {
  motion: "motion",
  no_recent_motion: "quiet",
  calibrating: "attention",
  unavailable: "unknown",
  no_presence_sensor: "unknown",
};

export function MotionCard() {
  const { t, lang } = useT();
  const { session } = useAuth();
  const motion = useMotion();
  if (!canSeeCluster(session?.role)) return null;
  const zones = motion.data?.zones ?? [];
  const unmapped = motion.data?.unmapped ?? [];
  return (
    <Card title={t("motion.title")}>
      <div className="muted small" style={{ marginBottom: 8 }}>{t("motion.caveat")}</div>
      {motion.isError && <div className="muted small">{t("motion.unavailableList")}</div>}
      {!motion.data && !motion.isError && <div className="muted small">{t("common.loading")}</div>}
      {zones.map((z) => (
        <div key={z.zone_id} className="row" style={{ marginBottom: 6 }}>
          <div className="grow">{z.label || z.zone_id}</div>
          {z.state !== "no_presence_sensor" && (
            <span className="muted small" title={z.sensors.map((s) => `${s.device_id}: ${s.reason}`).join("\n")}>
              {z.last_motion_ts ? t("motion.lastMotion", { ago: fmtAgo(z.last_motion_ts, lang) }) : t("motion.noMotionYet")}
            </span>
          )}
          <span className={`pill ${MOTION_PILL[z.state]}`}>{t(`motion.state.${z.state}`)}</span>
        </div>
      ))}
      {unmapped.length > 0 && (
        <div className="muted small" style={{ marginTop: 8 }}>
          {t("motion.unmapped", { ids: unmapped.map((s) => s.device_id).join(", ") })}
        </div>
      )}
    </Card>
  );
}
