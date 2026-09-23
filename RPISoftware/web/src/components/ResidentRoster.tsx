import type { Roster, RosterEntry } from "../api/types";

/** Maps a check-in status to a label + pill style. `unknown`/`no_response` mean "not yet
 *  confirmed safe" — the people a responder still has to account for. */
function statusMeta(status: string): { label: string; cls: string } {
  switch (status) {
    case "needs_help":
      return { label: "NEEDS HELP", cls: "alarm" };
    case "safe_outside":
      return { label: "Safe — outside", cls: "normal" };
    case "safe_inside":
      return { label: "Safe — inside", cls: "normal" };
    case "no_response":
      return { label: "No response", cls: "detection" };
    default:
      return { label: "Awaiting", cls: "detection" };
  }
}

function RosterRow({ entry }: { entry: RosterEntry }) {
  const meta = statusMeta(entry.status);
  return (
    <div className="row">
      <div className="grow">
        <div>{entry.display_name}</div>
        <div className="muted small">
          {entry.unit_label ?? entry.unit_id ?? "—"}
          {entry.phone ? ` · ${entry.phone}` : ""}
          {entry.ts ? ` · ${new Date(entry.ts).toLocaleTimeString()}` : ""}
        </div>
      </div>
      <span className={`pill ${meta.cls}`}>{meta.label}</span>
    </div>
  );
}

/** Incident roster with a safe / needs-help / awaiting summary, needs-help surfaced first. */
export function ResidentRoster({ roster }: { roster: Roster }) {
  if (roster.entries.length === 0) {
    return <div className="muted small">No residents registered for this building.</div>;
  }
  return (
    <div>
      <div className="grid cols-3" style={{ gap: 10, marginBottom: 12 }}>
        <div className={`metric ${roster.needs_help > 0 ? "danger" : ""}`}>
          <div className="n">{roster.needs_help}</div>
          <div className="l">Need help</div>
        </div>
        <div className={`metric ${roster.awaiting > 0 ? "" : "good"}`}>
          <div className="n">{roster.awaiting}</div>
          <div className="l">Awaiting</div>
        </div>
        <div className="metric good">
          <div className="n">{roster.safe}</div>
          <div className="l">Safe</div>
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
  if (entries.length === 0) {
    return <div className="muted small">No residents registered for this building.</div>;
  }
  return (
    <div>
      {entries.map((e) => (
        <RosterRow key={e.user_id} entry={e} />
      ))}
    </div>
  );
}
