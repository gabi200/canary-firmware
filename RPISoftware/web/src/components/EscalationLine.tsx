import { useEscalations } from "../api/hooks";
import { useT } from "../i18n";
import { fmtClock } from "../lib/time";
import { CheckIcon, WarningIcon } from "./Icons";

/** Retry budget of the backend's dispatch delivery. */
const MAX_ATTEMPTS = 4;

/** "Sent to dispatch (ARC) · 14:32" / "Delivery failed · retry 2/4"; nothing without deliveries
 *  (or on a backend without the escalations endpoint). */
export function EscalationLine({ incidentId, onDark }: { incidentId: string; onDark?: boolean }) {
  const { t, lang } = useT();
  const q = useEscalations(incidentId);
  const list = q.data ?? [];
  if (list.length === 0) return null;
  const delivered = list.filter((e) => e.delivered).sort((a, b) => b.ts.localeCompare(a.ts))[0];
  if (delivered) {
    return (
      <div className={`escalation ok ${onDark ? "on-dark" : ""}`} role="status">
        <CheckIcon />
        {t("escalation.sent", { time: fmtClock(delivered.ts, lang, false) })}
      </div>
    );
  }
  const attempts = Math.max(...list.map((e) => e.attempts ?? 0));
  return (
    <div className={`escalation failed ${onDark ? "on-dark" : ""}`} role="status">
      <WarningIcon />
      {t("escalation.failed", { n: Math.min(attempts, MAX_ATTEMPTS), max: MAX_ATTEMPTS })}
    </div>
  );
}
