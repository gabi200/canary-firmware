/**
 * Hub → Software: GitHub's newest commit on main, the commits not yet on every Pi, "Update all
 * Pis" and the rollout's progress (SoftwarePanel); on each Pi card the version it runs and
 * "Update this Pi" (PiSoftware). The Pis' canary-updater does the work (backend app.software);
 * a Pi that fails goes back to its previous version by itself.
 */
import { useState } from "react";

import { useSoftware, useSoftwareDismiss, useSoftwareFetch, useSoftwareUpdate } from "../../api/adminHooks";
import type { SoftwareCommit, SoftwareOverview } from "../../api/types";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { HubLine } from "../../components/HubStatus";
import { rich, useT } from "../../i18n";
import { piLabel } from "../../lib/cluster";
import { allBlocker, piBlocker, piLine, shortSha, targetCommit } from "../../lib/software";
import { fmtAgo, fmtDateTime } from "../../lib/time";

const FIRST = 5;

function Commit({ c }: { c: SoftwareCommit }) {
  const { lang } = useT();
  return (
    <li>
      <span className="mono">{shortSha(c.sha)}</span> {c.subject}{" "}
      <span className="muted" title={fmtDateTime(c.date, lang)}>
        · {c.author ? `${c.author} · ` : ""}
        {fmtAgo(c.date, lang)}
      </span>
    </li>
  );
}

function Rollout({ o }: { o: SoftwareOverview }) {
  const { t } = useT();
  const r = o.rollout;
  if (!r) return null;
  return (
    <div className="sw-rollout" aria-live="polite">
      <div className="hub-line-main">{t(r.outcome === "running" ? "sw.rolloutTitle" : "sw.rolloutLast", { sha: shortSha(r.commit) })}</div>
      <ol className="sw-steps">
        {r.order.map((name) => (
          <li key={name} className={`sw-step ${r.results[name] ?? "waiting"}`}>
            {o.mode === "triple" ? piLabel(name, t) : t("hub.singleTitle")}:{" "}
            <b>{t(`sw.rollout.${r.results[name] ?? "waiting"}` as "sw.rollout.waiting")}</b>
          </li>
        ))}
      </ol>
      <div className={`small ${r.outcome === "stopped" ? "t-attention" : "muted"}`}>
        {r.outcome === "running" && t("sw.rollout.running")}
        {r.outcome === "done" && t("sw.rollout.finished")}
        {r.outcome === "stopped" && t("sw.rollout.stopped", { reason: r.reason ?? "" })}
      </div>
    </div>
  );
}

export function SoftwarePanel() {
  const { t, lang } = useT();
  const sw = useSoftware();
  const fetchNow = useSoftwareFetch();
  const update = useSoftwareUpdate();
  const [showAll, setShowAll] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const o = sw.data;
  if (!o) return sw.isError ? <div className="err">{(sw.error as Error)?.message}</div> : null;

  const head = o.github.head;
  const target = targetCommit(o);
  const blocker = allBlocker(o);
  const commits = showAll ? o.incoming : o.incoming.slice(0, FIRST);
  const error = (update.error ?? fetchNow.error) as Error | null;

  return (
    <section className="card sw-panel">
      <h3>{t("sw.title")}</h3>
      {sw.isError && <div className="err">{t("sw.reconnecting")}</div>}
      <div className="sw-head">
        <div className="sw-head-text">
          <div className="muted small">{t("sw.github")}</div>
          {head ? (
            <div>
              <span className="mono">{shortSha(head.sha)}</span> <b>{head.subject}</b>{" "}
              <span className="muted small">· {fmtAgo(head.date, lang)}</span>
            </div>
          ) : (
            <div className="muted">{t("sw.githubUnknown")}</div>
          )}
          <div className="muted small">{t("sw.checked", { ago: fmtAgo(o.github.fetched_at, lang) })}</div>
          {o.github.fetch_error && <div className="small t-attention">{t("sw.fetchError", { msg: o.github.fetch_error })}</div>}
        </div>
        <button
          type="button"
          className="btn small-btn"
          disabled={!o.configured || fetchNow.isPending}
          onClick={() => fetchNow.mutate()}
        >
          {fetchNow.isPending ? t("sw.checking") : t("sw.checkNow")}
        </button>
      </div>

      {o.incoming.length > 0 ? (
        <>
          <div className="sw-new">{t("sw.newCommits", { n: o.incoming.length })}</div>
          <ul className="sw-commits small">
            {commits.map((c) => (
              <Commit key={c.sha} c={c} />
            ))}
          </ul>
          {o.incoming.length > FIRST && (
            <button type="button" className="btn small-btn" onClick={() => setShowAll(!showAll)}>
              {showAll ? t("sw.showLess") : t("sw.showAll", { n: o.incoming.length })}
            </button>
          )}
        </>
      ) : (
        head &&
        o.nodes.every((n) => n.status?.commit?.sha === head.sha) && <div className="muted small sw-new">{t("sw.noNew")}</div>
      )}

      <div className="sw-actions">
        <button type="button" className="btn primary" disabled={!!blocker || update.isPending} onClick={() => setConfirm(true)}>
          {t("sw.updateAll")}
        </button>
        {blocker && <span className="muted small">{t(blocker)}</span>}
      </div>
      {error && <div className="err">{error.message}</div>}
      <Rollout o={o} />

      {confirm && target && (
        <ConfirmDialog
          title={t("sw.confirmAllTitle")}
          confirmLabel={t("sw.confirm")}
          busy={update.isPending}
          onCancel={() => setConfirm(false)}
          onConfirm={() => update.mutate({ scope: "all", commit: target }, { onSettled: () => setConfirm(false) })}
        >
          <p>{t("sw.confirmAllBody", { sha: `${shortSha(target)} (${head?.subject ?? ""})` })}</p>
        </ConfirmDialog>
      )}
    </section>
  );
}

/** Bottom of a Pi card: its version, its update state, "Update this Pi". */
export function PiSoftware({ name }: { name: string }) {
  const { t } = useT();
  const sw = useSoftware();
  const update = useSoftwareUpdate();
  const dismiss = useSoftwareDismiss();
  const [confirm, setConfirm] = useState(false);
  const o = sw.data;
  const node = o?.nodes.find((n) => n.name === name);
  if (!o || !node) return null;

  const s = node.status;
  const line = piLine(node);
  const blocker = piBlocker(o, name);
  const target = targetCommit(o);
  const label = o.mode === "triple" ? piLabel(name, t) : t("hub.singleTitle");
  const showLog = !!s && (s.state === "rolled_back" || s.state === "failed") && s.log.length > 0;
  const error = (update.error ?? dismiss.error) as Error | null;

  return (
    <div className="sw-pi">
      <div className="small">
        {s?.commit ? (
          <>
            {rich(t("sw.runs"), { sha: <span className="mono">{shortSha(s.commit.sha)}</span> })} {s.commit.subject}
          </>
        ) : (
          <span className="muted">{t("sw.unknownCommit")}</span>
        )}
      </div>
      <ul className="hub-lines sw-pi-line">
        <HubLine line={{ tone: line.tone, text: t(line.key, line.vars), sub: s?.error ?? undefined }} />
      </ul>
      {showLog && (
        <details className="small">
          <summary>{t("sw.log")}</summary>
          <pre className="sw-log">{s.log.join("\n")}</pre>
        </details>
      )}
      <div className="sw-actions">
        <button
          type="button"
          className="btn small-btn"
          disabled={!!blocker || update.isPending}
          title={blocker ? t(blocker) : undefined}
          onClick={() => setConfirm(true)}
        >
          {t("sw.updateOne")}
        </button>
        {(s?.state === "rolled_back" || s?.state === "failed") && (
          <button type="button" className="btn small-btn" disabled={dismiss.isPending} onClick={() => dismiss.mutate(name)}>
            {t("sw.dismiss")}
          </button>
        )}
        {blocker && blocker !== "sw.block.upToDate" && <span className="muted small">{t(blocker)}</span>}
      </div>
      {error && <div className="err">{error.message}</div>}
      {confirm && target && (
        <ConfirmDialog
          title={t("sw.confirmOneTitle", { pi: label })}
          confirmLabel={t("sw.confirm")}
          busy={update.isPending}
          onCancel={() => setConfirm(false)}
          onConfirm={() => update.mutate({ scope: name, commit: target }, { onSettled: () => setConfirm(false) })}
        >
          <p>{t("sw.confirmOneBody", { sha: `${shortSha(target)} (${o.github.head?.subject ?? ""})` })}</p>
        </ConfirmDialog>
      )}
    </div>
  );
}
