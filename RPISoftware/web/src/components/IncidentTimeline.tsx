import type { IncidentEvent } from "../api/types";
import { parseTs } from "../lib/time";
import { StatusPill } from "./StatusPill";

function fmt(ts: string): string {
  return new Date(parseTs(ts)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export function IncidentTimeline({ events }: { events: IncidentEvent[] }) {
  if (events.length === 0) return <div className="muted small">No events yet.</div>;
  return (
    <div>
      {events.map((e) => (
        <div className="row" key={e.id}>
          <StatusPill state={e.to_state} />
          <div className="grow">
            <div className="small">
              {e.from_state} → {e.to_state}
            </div>
            <div className="muted small">
              {e.reason} · {e.actor}
            </div>
          </div>
          <div className="muted small">{fmt(e.ts)}</div>
        </div>
      ))}
    </div>
  );
}
