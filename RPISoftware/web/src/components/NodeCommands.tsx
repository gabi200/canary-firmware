/**
 * Hardware test controls of one sensor node: the command buttons for its kind, a live status
 * chip for the command just sent ("Sent…" -> "Done" / "Rejected: <why>" / "No answer"), the
 * last command the hub knows of, and a popover with the last 20 commands.
 * Air: TEST (4 s self-test, buzzer + LED) and SILENCE. Water: CLOSE (asks first) / OPEN the
 * valve and SILENCE. Managers and admins only; buttons are disabled, with the reason, while the
 * node is offline, while a command waits for its answer and for 3 s after each command.
 */
import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useNodeCommandHistory } from "../api/adminHooks";
import type { CommandRecord, NodeCommandName, NodeKind } from "../api/types";
import { useAuth } from "../auth/AuthContext";
import { useT, type Lang, type TFn } from "../i18n";
import {
  COMMAND_SPACING_MS,
  KIND_COMMANDS,
  commandDetailLabel,
  commandErrorLabel,
  commandName,
  isPending,
  sendNodeCommand,
  useLiveCommand,
  type LiveCommand,
} from "../lib/commands";
import { tokenLabel } from "../lib/labels";
import { fmtAgo, fmtClock, fmtDateTime, parseTs } from "../lib/time";
import { useNow } from "../lib/useNow";
import { ConfirmDialog } from "./ConfirmDialog";
import { BellIcon, BellOffIcon, CheckIcon, ClockIcon, CloseIcon, HistoryIcon, ValveIcon, WarningIcon } from "./Icons";

/** What a node card needs (NodeOut fits). */
export interface CommandableNode {
  id: string;
  name: string;
  kind: NodeKind;
  online: boolean;
  last_command?: CommandRecord | null;
}

/** Roles the hub accepts device commands from on the dashboard. */
export function canCommand(role: string | undefined): boolean {
  return role === "hoa_manager" || role === "system_admin" || role === "technician";
}

const ICON: Record<NodeCommandName, typeof BellIcon> = {
  TEST: BellIcon,
  SILENCE: BellOffIcon,
  CLOSE: ValveIcon,
  OPEN: ValveIcon,
};

/** a settled live chip stays up this long, then the "last command" line takes over */
const CHIP_MS = 60_000;

/** Live status chip of a command sent from this browser. */
export function CommandChip({ c }: { c: LiveCommand }) {
  const { t } = useT();
  const name = <b>{commandName(c.command, t)}</b>;
  let tone = "bad";
  let icon = <WarningIcon />;
  let text: string;
  switch (c.state) {
    case "sending":
    case "sent":
      tone = "pending";
      icon = <span className="spinner" aria-hidden="true" />;
      text = t(c.state === "sending" ? "nodecmd.sending" : "nodecmd.sent");
      break;
    case "accepted":
      tone = "ok";
      icon = <CheckIcon />;
      text = `${t("nodecmd.accepted")}${c.detail ? ` · ${commandDetailLabel(c.detail, t)}` : ""}`;
      break;
    case "rejected":
      icon = <CloseIcon />;
      text = c.detail ? t("nodecmd.rejected", { detail: commandDetailLabel(c.detail, t) }) : t("nodecmd.rejectedPlain");
      break;
    case "timeout":
      tone = "warn";
      icon = <ClockIcon />;
      text = t("nodecmd.timeout");
      break;
    default:
      text = t("nodecmd.error", { msg: c.error ? commandErrorLabel(c.error, t) : "" });
  }
  return (
    <span className={`cmd-chip ${tone}`} role="status">
      {icon}
      <span className="cmd-chip-text">
        {name} · {text}
      </span>
    </span>
  );
}

const RESULT_TONE: Record<string, string> = { accepted: "t-ok", rejected: "t-danger", timeout: "t-attention" };

/** "passed" / "failed (the probe is wet)" / "no answer" for a stored command. */
export function recordResult(rec: CommandRecord, t: TFn): string {
  const base = tokenLabel(t, rec.command === "TEST" ? "nodecmd.res.test" : "nodecmd.res.cmd", rec.status);
  return rec.status === "rejected" && rec.detail ? `${base} (${commandDetailLabel(rec.detail, t)})` : base;
}

/** "Last test: passed · 2 min ago" (or "Last command: Valve closing · done · …"). */
export function LastCommandLine({ rec, lang, t }: { rec: CommandRecord | null | undefined; lang: Lang; t: TFn }) {
  if (!rec) return <span className="muted">{t("nodecmd.neverTested")}</span>;
  const vars = { result: recordResult(rec, t), ago: fmtAgo(rec.result_ts ?? rec.sent_ts, lang), cmd: commandName(rec.command, t) };
  return (
    <span
      className={RESULT_TONE[rec.status] ?? "muted"}
      title={`${fmtDateTime(rec.result_ts ?? rec.sent_ts, lang)}${rec.requested_by_name ? ` · ${t("nodecmd.by", { name: rec.requested_by_name })}` : ""}`}
    >
      {t(rec.command === "TEST" ? "nodecmd.lastTest" : "nodecmd.lastCommand", vars)}
    </span>
  );
}

function sameDay(a: number, b: number) {
  return new Date(a).toDateString() === new Date(b).toDateString();
}

function HistoryPopover({ nodeId, onClose }: { nodeId: string; onClose: () => void }) {
  const { t, lang } = useT();
  const history = useNodeCommandHistory(nodeId, true);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const down = (e: MouseEvent) => {
      const el = box.current;
      if (el && !el.contains(e.target as Node) && !(e.target as HTMLElement).closest?.(".ncmd-history-btn")) onClose();
    };
    // capture phase + stop: Esc closes only the popover, not a dialog around it (zone view)
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.stopPropagation();
      onClose();
    };
    document.addEventListener("mousedown", down);
    document.addEventListener("keydown", key, true);
    return () => {
      document.removeEventListener("mousedown", down);
      document.removeEventListener("keydown", key, true);
    };
  }, [onClose]);

  const now = Date.now();
  return (
    <div className="ncmd-pop" ref={box} role="dialog" aria-label={t("nodecmd.historyTitle")}>
      <div className="ncmd-pop-head">
        <b>{t("nodecmd.historyTitle")}</b>
        <span className="spacer" />
        <button type="button" className="btn icon-btn" onClick={onClose} aria-label={t("common.close")}>
          <CloseIcon />
        </button>
      </div>
      {history.isError && !history.data ? (
        <div className="err">{t("nodecmd.historyUnavailable", { msg: (history.error as Error).message })}</div>
      ) : !history.data ? (
        <div className="muted small">{t("common.loading")}</div>
      ) : history.data.length === 0 ? (
        <div className="muted small">{t("nodecmd.historyEmpty")}</div>
      ) : (
        <ol className="ncmd-hist">
          {history.data.map((c) => {
            const ts = parseTs(c.sent_ts);
            return (
              <li key={c.command_id}>
                <span className="ncmd-hist-time" title={fmtDateTime(c.sent_ts, lang)}>
                  {sameDay(ts, now) ? fmtClock(c.sent_ts, lang) : fmtDateTime(c.sent_ts, lang)}
                </span>
                <span className="ncmd-hist-cmd">{commandName(c.command, t)}</span>
                <span className={`ncmd-hist-res ${RESULT_TONE[c.status] ?? "muted"}`}>{recordResult(c, t)}</span>
                {c.requested_by_name && <span className="ncmd-hist-by muted">{t("nodecmd.by", { name: c.requested_by_name })}</span>}
              </li>
            );
          })}
        </ol>
      )}
    </div>
  );
}

interface Props {
  node: CommandableNode;
  /** compact: one row of small buttons (sensor pages); full: big buttons (Devices grid) */
  variant?: "full" | "compact";
}

export function NodeCommands({ node, variant = "full" }: Props) {
  const { t, lang } = useT();
  const { session, token } = useAuth();
  const qc = useQueryClient();
  const live = useLiveCommand(node.id);
  const [confirmClose, setConfirmClose] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const pending = isPending(live);
  const recent = !!live && (pending || Date.now() - (live.settledAt ?? live.startedAt) < Math.max(CHIP_MS, COMMAND_SPACING_MS));
  const now = useNow(1000, recent);
  if (!canCommand(session?.role)) return null;

  const spacing = !!live && now - live.startedAt < COMMAND_SPACING_MS;
  const chipVisible = !!live && (pending || now - (live.settledAt ?? live.startedAt) < CHIP_MS);
  const reason = !node.online
    ? t("nodecmd.offlineReason")
    : pending
      ? t("nodecmd.busyReason")
      : spacing
        ? t("nodecmd.spacingReason")
        : null;
  const send = (command: NodeCommandName) => {
    void sendNodeCommand({ token, nodeId: node.id, command, qc });
  };
  const small = variant === "compact" ? "small-btn" : "";
  const commands = KIND_COMMANDS[node.kind] ?? [];

  return (
    <div className={`ncmd ${variant}`}>
      <div className="ncmd-row" role="group" aria-label={t("nodecmd.aria")}>
        {commands.map((c) => {
          const Icon = ICON[c];
          const tone = c === "TEST" ? "primary" : c === "CLOSE" ? "valve-close" : "";
          return (
            <button
              key={c}
              type="button"
              className={`btn ${tone} ${small}`}
              disabled={!!reason}
              title={reason ?? undefined}
              onClick={() => (c === "CLOSE" ? setConfirmClose(true) : send(c))}
            >
              <Icon /> {t(`nodecmd.${c}`)}
            </button>
          );
        })}
        <button
          type="button"
          className={`btn ncmd-history-btn ${small}`}
          aria-expanded={showHistory}
          onClick={() => setShowHistory((v) => !v)}
        >
          <HistoryIcon /> {t("nodecmd.history")}
        </button>
        {variant === "compact" && chipVisible && live && <CommandChip c={live} />}
      </div>
      {!node.online && (
        <div className="ncmd-reason">
          <WarningIcon /> {t("nodecmd.offlineReason")}
        </div>
      )}
      {variant === "full" && (
        <div className="ncmd-status">
          {chipVisible && live ? <CommandChip c={live} /> : <LastCommandLine rec={node.last_command} lang={lang} t={t} />}
        </div>
      )}
      {variant === "compact" && !chipVisible && node.last_command !== undefined && (
        <div className="ncmd-status small">
          <LastCommandLine rec={node.last_command} lang={lang} t={t} />
        </div>
      )}
      {showHistory && <HistoryPopover nodeId={node.id} onClose={() => setShowHistory(false)} />}
      {confirmClose && (
        <ConfirmDialog
          title={t("nodecmd.confirmCloseTitle", { name: node.name || node.id })}
          confirmLabel={t("nodecmd.CLOSE")}
          danger
          onCancel={() => setConfirmClose(false)}
          onConfirm={() => {
            setConfirmClose(false);
            send("CLOSE");
          }}
        >
          <p>{t("nodecmd.confirmCloseBody")}</p>
        </ConfirmDialog>
      )}
    </div>
  );
}
