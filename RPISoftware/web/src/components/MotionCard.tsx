/**
 * Motion per room from the ESPectre Wi-Fi boards (staff only): motion detected / no recent motion /
 * calibrating / unavailable / no presence sensor, with the age of the last motion. Movement only:
 * never a person count, never "empty". Renders nothing for roles the endpoint refuses.
 *
 * Rooms with a presence board are small boxes in a grid; the (usually many) rooms without one
 * collapse into a single muted line, their names in its tooltip.
 */
import { useMotion, useZones } from "../api/hooks";
import type { MotionState } from "../api/types";
import { useAuth } from "../auth/AuthContext";
import { pluralCategory, useT } from "../i18n";
import { canSeeCluster } from "../lib/cluster";
import { buildZoneNames } from "../lib/labels";
import { fmtAgo } from "../lib/time";
import { Card } from "./Card";
import { ActivityIcon, ClockIcon, DashedLineIcon, TrendFlatIcon } from "./Icons";
import type { CellTone } from "./StateGrid";

export const MOTION_PILL: Record<MotionState, string> = {
  motion: "motion",
  no_recent_motion: "quiet",
  calibrating: "attention",
  unavailable: "unknown",
  no_presence_sensor: "unknown",
};

const TONE: Record<Exclude<MotionState, "no_presence_sensor">, CellTone> = {
  motion: "motion",
  no_recent_motion: "quiet",
  calibrating: "attention",
  unavailable: "none",
};

const MARK: Record<Exclude<MotionState, "no_presence_sensor">, () => JSX.Element> = {
  motion: () => <ActivityIcon />,
  no_recent_motion: () => <TrendFlatIcon />,
  calibrating: () => <ClockIcon />,
  unavailable: () => <DashedLineIcon />,
};

export function MotionCard() {
  const { t, lang } = useT();
  const { session } = useAuth();
  const motion = useMotion();
  const zoneList = useZones();
  if (!canSeeCluster(session?.role)) return null;
  const names = buildZoneNames(zoneList.data);
  const nameOf = (z: { zone_id: string; label: string }) => names.get(z.zone_id) ?? (z.label || z.zone_id);
  const zones = motion.data?.zones ?? [];
  const unmapped = motion.data?.unmapped ?? [];
  const withSensor = zones.filter((z) => z.state !== "no_presence_sensor");
  const without = zones.filter((z) => z.state === "no_presence_sensor");
  const withoutNames = without.map(nameOf).join(", ");
  const summary = t(`motion.noSensorSummary.${pluralCategory(lang, without.length)}`, { n: without.length });
  return (
    <Card title={t("motion.title")} className="motion-card">
      <div className="muted small" style={{ marginBottom: 8 }}>{t("motion.caveat")}</div>
      {motion.isError && <div className="muted small">{t("motion.unavailableList")}</div>}
      {!motion.data && !motion.isError && <div className="muted small">{t("common.loading")}</div>}
      {withSensor.length > 0 && (
        <ul className="mgrid">
          {withSensor.map((z) => {
            // the no_presence_sensor rooms are filtered out above
            const state = z.state as Exclude<MotionState, "no_presence_sensor">;
            const Mark = MARK[state];
            const age = z.last_motion_ts ? t("motion.lastMotion", { ago: fmtAgo(z.last_motion_ts, lang) }) : t("motion.noMotionYet");
            const reasons = z.sensors.map((s) => `${s.device_id}: ${s.reason}`).join("\n");
            return (
              <li key={z.zone_id} className="mroom" data-tone={TONE[state]} title={reasons || undefined}>
                <span className="mroom-name">{nameOf(z)}</span>
                <Mark />
                <span className="mroom-state">{t(`motion.state.${state}`)}</span>
                <span className="mroom-age">{age}</span>
              </li>
            );
          })}
        </ul>
      )}
      {without.length > 0 && (
        <div className={`muted small${withSensor.length > 0 ? " mnone" : ""}`} title={withoutNames}>
          {summary}
          <span className="sr-only">: {withoutNames}</span>
        </div>
      )}
      {unmapped.length > 0 && (
        <div className="muted small" style={{ marginTop: 8 }}>
          {t("motion.unmapped", { ids: unmapped.map((s) => s.device_id).join(", ") })}
        </div>
      )}
    </Card>
  );
}
