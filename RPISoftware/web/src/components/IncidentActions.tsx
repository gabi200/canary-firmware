import { useIncidentAction } from "../api/hooks";
import type { Incident } from "../api/types";

const CLOSED = new Set(["resolution", "false_alarm", "normal"]);
const ALARMING = new Set(["alarm", "escalation", "evacuation"]);

export function IncidentActions({ incident }: { incident: Incident }) {
  const action = useIncidentAction();
  const closed = CLOSED.has(incident.state);
  const alarming = ALARMING.has(incident.state);
  const pending = action.isPending;

  if (closed) return <div className="muted small">Incident closed ({incident.state}).</div>;

  return (
    <div>
      <div className="btn-row">
        <button
          className="btn warn"
          disabled={pending || incident.state === "evacuation"}
          onClick={() => action.mutate({ incidentId: incident.id, action: "order-evacuation" })}
        >
          Order evacuation
        </button>
        <button
          className="btn"
          disabled={pending || !alarming}
          onClick={() => action.mutate({ incidentId: incident.id, action: "resolve" })}
        >
          Resolve
        </button>
        <button
          className="btn danger"
          disabled={pending || alarming}
          title={
            alarming
              ? "Residents are already alarmed — this can no longer be a false alarm. Use Resolve."
              : undefined
          }
          onClick={() => action.mutate({ incidentId: incident.id, action: "dismiss" })}
        >
          Dismiss (false alarm)
        </button>
      </div>
      {alarming && (
        <div className="muted small" style={{ marginTop: 8 }}>
          Residents alarmed — once the hazard clears, use <strong>Resolve</strong> (a dismissal as
          false alarm is no longer possible).
        </div>
      )}
      {action.isError && <div className="err" style={{ marginTop: 8 }}>{(action.error as Error).message}</div>}
    </div>
  );
}
