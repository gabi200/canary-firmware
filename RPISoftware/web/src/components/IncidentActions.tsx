import { useIncidentAction } from "../api/hooks";
import type { Incident } from "../api/types";
import { rich, useT } from "../i18n";
import { stateLabel } from "../lib/labels";
import { SafetySign } from "./SafetySigns";

const CLOSED = new Set(["resolution", "false_alarm", "normal"]);
const ALARMING = new Set(["alarm", "escalation", "evacuation"]);

export function IncidentActions({ incident }: { incident: Incident }) {
  const { t } = useT();
  const action = useIncidentAction();
  const closed = CLOSED.has(incident.state);
  const alarming = ALARMING.has(incident.state);
  const pending = action.isPending;

  if (closed) {
    return (
      <div className="muted small">{t("actions.closed", { state: stateLabel(incident.state, t) })}</div>
    );
  }

  return (
    <div>
      <div className="btn-row">
        <button
          className="btn warn"
          disabled={pending || incident.state === "evacuation"}
          onClick={() => action.mutate({ incidentId: incident.id, action: "order-evacuation" })}
        >
          <SafetySign code="E002" size={20} className="btn-sign" />
          {t("actions.orderEvacuation")}
        </button>
        <button
          className="btn"
          disabled={pending || !alarming}
          onClick={() => action.mutate({ incidentId: incident.id, action: "resolve" })}
        >
          {t("actions.resolve")}
        </button>
        <button
          className="btn danger"
          disabled={pending || alarming}
          title={alarming ? t("actions.dismissBlocked") : undefined}
          onClick={() => action.mutate({ incidentId: incident.id, action: "dismiss" })}
        >
          {t("actions.dismiss")}
        </button>
      </div>
      {alarming && (
        <div className="muted small" style={{ marginTop: 8 }}>
          {rich(t("actions.alarmedNote"), { resolve: <strong>{t("actions.resolve")}</strong> })}
        </div>
      )}
      {action.isError && <div className="err" style={{ marginTop: 8 }}>{(action.error as Error).message}</div>}
    </div>
  );
}
