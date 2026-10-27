import { useEvidenceTimeline } from "../api/hooks";
import { useT } from "../i18n";
import { prettyId, sensorLabel } from "../lib/labels";
import { fmtClock, fmtDuration, parseTs } from "../lib/time";

/** What each sensor reported and when, from stored readings only. While replaying, sensors that had
 *  not crossed yet at the replay time are dimmed. Stored estimates and motion are counted apart:
 *  they are not observations of the hazard. */
export function ObservedSequence({
  incidentId,
  replayT,
  zoneNames,
}: {
  incidentId: string;
  replayT: number | null;
  zoneNames: Map<string, string>;
}) {
  const { t, lang } = useT();
  const data = useEvidenceTimeline(incidentId).data;
  if (!data || !data.devices.length) return null;

  return (
    <section className="observed">
      <div className="panel-label">{t("observed.title")}</div>
      <ol className="observed-list">
        {data.devices.map((d) => {
          const pending = replayT != null && (d.first_over_ts == null || parseTs(d.first_over_ts) > replayT);
          const gapS = d.gaps.reduce((sum, g) => sum + g.seconds, 0);
          return (
            <li key={d.device_id} className={pending ? "pending" : undefined}>
              <span className="observed-rank">{d.order ?? "–"}</span>
              <span className="grow">
                <b>{sensorLabel(d.sensor_type, t)}</b> · {zoneNames.get(d.zone_id) ?? prettyId(d.zone_id)}{" "}
                <span className="muted small">({d.device_id})</span>
              </span>
              <span className="small">
                {d.first_over_ts
                  ? t("observed.crossed", { time: fmtClock(d.first_over_ts, lang) })
                  : t("observed.neverCrossed")}
              </span>
              {d.gaps.length > 0 && (
                <span className="small observed-warn">
                  {t("observed.gaps", { n: d.gaps.length, total: fmtDuration(gapS * 1000, lang) })}
                </span>
              )}
              {d.out_of_order > 0 && (
                <span className="small observed-warn">{t("observed.outOfOrder", { n: d.out_of_order })}</span>
              )}
            </li>
          );
        })}
      </ol>
      <div className="muted small">
        {t("observed.apart", { estimates: data.estimates.length, motion: data.motion.length })}
        {data.truncated && <> · {t("observed.truncated")}</>}
      </div>
    </section>
  );
}
