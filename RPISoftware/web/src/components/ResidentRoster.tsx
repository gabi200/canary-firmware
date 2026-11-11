import type { Roster, RosterEntry } from "../api/types";
import { useT, type MsgKey, type TFn } from "../i18n";
import { fmtClock } from "../lib/time";

/** Maps a check-in status to a label + pill style. `unknown`/`no_response` mean "not yet
 *  confirmed safe" — the people a responder still has to account for. */
function statusMeta(status: string, t: TFn): { label: string; cls: string } {
  switch (status) {
    case "needs_help":
      return { label: t("roster.needsHelp"), cls: "alarm" };
    case "safe_outside":
      return { label: t("roster.safeOutside"), cls: "normal" };
    case "safe_inside":
      return { label: t("roster.safeInside"), cls: "normal" };
    case "no_response":
      return { label: t("roster.noResponse"), cls: "detection" };
    default:
      return { label: t("roster.awaiting"), cls: "detection" };
  }
}

/** Names, unit labels and phone numbers are building data: shown verbatim. */
function RosterRow({ entry }: { entry: RosterEntry }) {
  const { t, lang } = useT();
  const meta = statusMeta(entry.status, t);
  return (
    <div className="row">
      <div className="grow">
        <div>{entry.display_name}</div>
        <div className="muted small">
          {entry.unit_label ?? entry.unit_id ?? "—"}
          {entry.phone ? ` · ${entry.phone}` : ""}
          {entry.ts ? ` · ${fmtClock(entry.ts, lang)}` : ""}
        </div>
      </div>
      {entry.location && <span className="tag">{t(`where.${entry.location}` as MsgKey)}</span>}
      <span className={`pill ${meta.cls}`}>{meta.label}</span>
    </div>
  );
}

/** Incident roster with a safe / needs-help / awaiting summary, needs-help surfaced first. */
export function ResidentRoster({ roster }: { roster: Roster }) {
  const { t } = useT();
  if (roster.entries.length === 0) {
    return <div className="muted small">{t("roster.empty")}</div>;
  }
  return (
    <div>
      <div className="grid cols-3 metric-row" style={{ gap: 10, marginBottom: 12 }}>
        <div className={`metric ${roster.needs_help > 0 ? "danger" : ""}`}>
          <div className="n">{roster.needs_help}</div>
          <div className="l">{t("roster.metricNeedHelp")}</div>
        </div>
        <div className={`metric ${roster.awaiting > 0 ? "" : "good"}`}>
          <div className="n">{roster.awaiting}</div>
          <div className="l">{t("roster.awaiting")}</div>
        </div>
        <div className="metric good">
          <div className="n">{roster.safe}</div>
          <div className="l">{t("roster.metricSafe")}</div>
        </div>
      </div>
      {roster.entries.map((e) => (
        <RosterRow key={e.user_id} entry={e} />
      ))}
    </div>
  );
}

/** Plain named-resident list (no incident context) for the manager dashboard. */
export function ResidentList({ entries }: { entries: RosterEntry[] }) {
  const { t } = useT();
  if (entries.length === 0) {
    return <div className="muted small">{t("roster.empty")}</div>;
  }
  return (
    <div>
      {entries.map((e) => (
        <RosterRow key={e.user_id} entry={e} />
      ))}
    </div>
  );
}
