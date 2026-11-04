import { useHubMode, useSetHubMode } from "../api/hooks";
import { useAuth } from "../auth/AuthContext";
import { useT } from "../i18n";

/** A real alarm while the hub shows Demo: every role sees it; only managers can switch. */
export function RealAlarmBanner() {
  const { t } = useT();
  const { session } = useAuth();
  const hubMode = useHubMode();
  const setMode = useSetHubMode();
  if (!(hubMode?.mode === "demo" && hubMode.live_alarm)) return null;
  const canSwitch = session?.role === "system_admin" || session?.role === "hoa_manager";
  return (
    <div className="real-alarm-banner" role="alert">
      <strong>{t("mode.realAlarm")}</strong>
      <div className="spacer" style={{ flex: 1 }} />
      {canSwitch && (
        <button className="btn danger" disabled={setMode.isPending} onClick={() => setMode.mutate("real")}>
          {t("mode.switchToReal")}
        </button>
      )}
    </div>
  );
}
