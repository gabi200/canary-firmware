/**
 * "Test all": TEST on every online air sensor of the scope, one after the other, with a live
 * checklist. Each sensor gets its answer (or the 15 s timeout) before the next one starts, then
 * a pause so the 4 s buzzers do not overlap; a 429 (3 s spacing) is retried once. Never sends
 * CLOSE (or anything else) to water sensors.
 */
import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";

import type { NodeOut } from "../../api/types";
import { useAuth } from "../../auth/AuthContext";
import { CommandChip } from "../../components/NodeCommands";
import { CheckIcon, ClockIcon, CloseIcon, StopIcon, WarningIcon } from "../../components/Icons";
import { useT } from "../../i18n";
import {
  COMMAND_SPACING_MS,
  commandDetailLabel,
  commandErrorLabel,
  sendNodeCommand,
  useLiveCommands,
  type LiveCommand,
} from "../../lib/commands";
import { fmtNumber } from "../../lib/format";

const SELF_TEST_MS = 4_000;
const sleep = (ms: number) => new Promise((r) => window.setTimeout(r, ms));

interface Step {
  nodeId: string;
  name: string;
  room: string;
  result: LiveCommand | null;
  skipped: boolean;
}

function StepResult({ s, running }: { s: Step; running: boolean }) {
  const { t } = useT();
  const live = useLiveCommands().get(s.nodeId);
  if (running && live) return <CommandChip c={live} />;
  if (s.skipped) return <span className="muted">{t("testall.skipped")}</span>;
  const r = s.result;
  if (!r) return <span className="muted">{t("testall.waiting")}</span>;
  if (r.state === "accepted")
    return (
      <span className="t-ok tl-res">
        <CheckIcon /> {t("nodecmd.accepted")}
        {r.detail ? ` · ${commandDetailLabel(r.detail, t)}` : ""}
      </span>
    );
  if (r.state === "rejected")
    return (
      <span className="t-danger tl-res">
        <CloseIcon /> {r.detail ? t("nodecmd.rejected", { detail: commandDetailLabel(r.detail, t) }) : t("nodecmd.rejectedPlain")}
      </span>
    );
  if (r.state === "timeout")
    return (
      <span className="t-attention tl-res">
        <ClockIcon /> {t("nodecmd.timeout")}
      </span>
    );
  return (
    <span className="t-danger tl-res">
      <WarningIcon /> {t("nodecmd.error", { msg: r.error ? commandErrorLabel(r.error, t) : "" })}
    </span>
  );
}

interface Props {
  /** online air sensors, in display order */
  targets: NodeOut[];
  /** where they are: "Ap. 12", "Ap. 12 · Bucătărie", "Whole building" */
  scope: string;
  roomOf: (n: NodeOut) => string;
  onClose: () => void;
}

export function TestAllPanel({ targets, scope, roomOf, onClose }: Props) {
  const { t, lang } = useT();
  const { token } = useAuth();
  const qc = useQueryClient();
  const [steps, setSteps] = useState<Step[]>(() =>
    targets.map((n) => ({ nodeId: n.id, name: n.name || n.id, room: roomOf(n), result: null, skipped: false })),
  );
  const [current, setCurrent] = useState(-1);
  const [running, setRunning] = useState(false);
  const [stopped, setStopped] = useState(false);
  const cancel = useRef(false);
  const started = useRef(false);

  // stop on unmount (StrictMode's simulated remount re-arms it before the run's next step)
  useEffect(() => {
    cancel.current = false;
    return () => {
      cancel.current = true;
    };
  }, []);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    cancel.current = false;
    void (async () => {
      setRunning(true);
      const list = steps;
      for (let i = 0; i < list.length; i++) {
        if (cancel.current) break;
        setCurrent(i);
        let res = await sendNodeCommand({ token, nodeId: list[i].nodeId, command: "TEST", qc });
        if (res.state === "error" && res.error?.status === 429 && !cancel.current) {
          await sleep(COMMAND_SPACING_MS + 300);
          if (!cancel.current) res = await sendNodeCommand({ token, nodeId: list[i].nodeId, command: "TEST", qc });
        }
        setSteps((s) => s.map((x, j) => (j === i ? { ...x, result: res } : x)));
        if (i < list.length - 1 && !cancel.current) await sleep(res.state === "accepted" ? SELF_TEST_MS + 500 : 800);
      }
      if (cancel.current) setSteps((s) => s.map((x) => (x.result ? x : { ...x, skipped: true })));
      setCurrent(-1);
      setRunning(false);
    })();
    // the run starts once, on mount, with the targets it was opened with
  }, []);

  const done = steps.filter((s) => s.result).length;
  const ok = steps.filter((s) => s.result?.state === "accepted").length;
  const bad = steps.filter((s) => s.result && (s.result.state === "rejected" || s.result.state === "error")).length;
  const none = steps.filter((s) => s.result?.state === "timeout").length;
  const n = (v: number) => fmtNumber(v, lang, 0);

  return (
    <section className="card testall" aria-live="polite">
      <div className="testall-head">
        <h3>
          {t("testall.title")} · {scope}
        </h3>
        <span className="muted">{t("testall.progress", { done: n(done), total: n(steps.length) })}</span>
        <span className="spacer" />
        {running ? (
          <button
            type="button"
            className="btn danger"
            onClick={() => {
              cancel.current = true;
              setStopped(true);
            }}
          >
            <StopIcon /> {t("testall.stop")}
          </button>
        ) : (
          <button type="button" className="btn" onClick={onClose}>
            {t("common.close")}
          </button>
        )}
      </div>
      <div className="progress testall-bar">
        <div style={{ width: `${steps.length ? (done / steps.length) * 100 : 0}%` }} />
      </div>
      <ol className="testall-list">
        {steps.map((s, i) => (
          <li key={s.nodeId} className={i === current ? "current" : ""}>
            <span className="tl-idx">{n(i + 1)}</span>
            <span className="tl-name">
              <b>{s.name}</b> <span className="muted">{s.room}</span>
            </span>
            <StepResult s={s} running={i === current} />
          </li>
        ))}
      </ol>
      {!running && (
        <div className="testall-sum">
          {stopped && <b>{t("testall.stopped")} </b>}
          <span className="t-ok">{t("testall.sumOk", { n: n(ok) })}</span>
          {" · "}
          <span className={bad ? "t-danger" : "muted"}>{t("testall.sumFailed", { n: n(bad) })}</span>
          {" · "}
          <span className={none ? "t-attention" : "muted"}>{t("testall.sumNone", { n: n(none) })}</span>
        </div>
      )}
    </section>
  );
}
