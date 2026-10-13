/**
 * Dispatch: a short text summary of the incident to read out or pass on (GET /incidents/{id}/brief).
 * Written by the LLM on the AI HAT+ 2 (up to a minute) or, without one, by a template (instant),
 * from database facts only. Never polled: the button asks for it, "Regenerate" asks again; an
 * older brief stays readable (dimmed) while a new one is written.
 */
import { ApiError } from "../api/client";
import { useIncidentBrief } from "../api/hooks";
import type { IncidentBrief } from "../api/types";
import { useT, type TFn } from "../i18n";
import { piLabel } from "../lib/cluster";
import { fmtClock, fmtDateTime } from "../lib/time";
import { Card } from "./Card";

function sourceLine(b: IncidentBrief, t: TFn): string {
  if (b.source !== "llm") return t("brief.byTemplate");
  const pi = piLabel(b.node, t);
  return b.model ? t("brief.byLlm", { model: b.model, pi }) : t("brief.byLlmNoModel", { pi });
}

/** 504: the proxy gave up waiting for the AI HAT+ 2. */
function errorText(e: unknown, t: TFn): string {
  const status = e instanceof ApiError ? e.status : undefined;
  if (status === 504) return t("brief.errTimeout");
  return t("brief.error", { msg: `${status ? `HTTP ${status} · ` : ""}${(e as Error)?.message ?? ""}` });
}

export function IncidentBriefCard({ incidentId }: { incidentId: string }) {
  const { t, lang } = useT();
  const brief = useIncidentBrief(incidentId);
  const b = brief.data;
  const busy = brief.isFetching;

  return (
    <Card title={t("brief.title")}>
      <div aria-live="polite">
        {busy && (
          <div className="brief-status">
            <span className="spinner" aria-hidden="true" />
            {t("brief.generating")}
          </div>
        )}
        {brief.isError && !busy && <div className="err">{errorText(brief.error, t)}</div>}
        {b ? (
          <div className={`brief ${busy ? "stale" : ""}`}>
            <p className="brief-text">{b.text}</p>
            <div className="muted small">
              {sourceLine(b, t)} ·{" "}
              <span title={fmtDateTime(b.generated_ts, lang)}>{t("brief.generatedAt", { time: fmtClock(b.generated_ts, lang) })}</span>
            </div>
            <div className="muted small">{t("brief.note")}</div>
          </div>
        ) : (
          !busy && <div className="muted small">{t("brief.intro")}</div>
        )}
      </div>
      <div className="brief-actions">
        <button type="button" className={`btn ${b ? "" : "primary"}`} disabled={busy} onClick={() => void brief.refetch()}>
          {b ? t("brief.regenerate") : t("brief.generate")}
        </button>
      </div>
    </Card>
  );
}
