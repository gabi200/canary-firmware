import type { IncidentEvent } from "../api/types";
import { useT } from "../i18n";
import { actorLabel, reasonLabel, stateLabel } from "../lib/labels";
import { fmtClock } from "../lib/time";
import { StatusPill } from "./StatusPill";

export function IncidentTimeline({ events }: { events: IncidentEvent[] }) {
  const { t, lang } = useT();
  if (events.length === 0) return <div className="muted small">{t("timeline.empty")}</div>;
  return (
    <div>
      {events.map((e) => (
        <div className="row" key={e.id}>
          <StatusPill state={e.to_state} />
          <div className="grow">
            <div className="small">
              {stateLabel(e.from_state, t)} → {stateLabel(e.to_state, t)}
            </div>
            <div className="muted small">
              {reasonLabel(e.reason, t)} · {actorLabel(e.actor, t)}
            </div>
          </div>
          <div className="muted small">{fmtClock(e.ts, lang)}</div>
        </div>
      ))}
    </div>
  );
}
