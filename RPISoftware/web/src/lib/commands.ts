/**
 * Live device commands (hardware test): one store shared by every node card, the "test all"
 * checklist and the WebSocket.
 *
 * Flow: POST /nodes/{id}/commands -> 202 `sent` -> the device answers on MQTT and the hub sends a
 * `command_result` WebSocket event (accepted | rejected). Fallback: while a command waits, the
 * commands list is polled every 2 s. No answer within 15 s -> `timeout` (the hub has no event
 * for it either: it computes `timeout` when the list is read).
 */
import { useSyncExternalStore } from "react";
import type { QueryClient } from "@tanstack/react-query";

import { ApiError, api } from "../api/client";
import type { CommandAck, CommandRecord, NodeCommandName, NodeKind, WsEvent } from "../api/types";
import type { TFn } from "../i18n";
import { tokenLabel } from "./labels";
import { parseTs } from "./time";

export const COMMAND_TIMEOUT_MS = 15_000;
/** the hub refuses a second command to the same node within 3 s (429) */
export const COMMAND_SPACING_MS = 3_000;
const POLL_MS = 2_000;

/** Commands a node kind accepts, in button order. */
export const KIND_COMMANDS: Record<NodeKind, NodeCommandName[]> = {
  air: ["TEST", "SILENCE"],
  water: ["CLOSE", "OPEN", "SILENCE"],
};

/** sending: HTTP request in flight; sent: waiting for the device; error: the hub refused it. */
export type LiveState = "sending" | "sent" | "accepted" | "rejected" | "timeout" | "error";

export interface LiveCommand {
  nodeId: string;
  command: NodeCommandName;
  state: LiveState;
  commandId: string | null;
  /** firmware token (self_test, silenced, open, closed, alarm_inactive, ...) */
  detail: string | null;
  /** HTTP refusal (state `error`) */
  error: { status?: number; message: string } | null;
  startedAt: number;
  settledAt: number | null;
}

export const isPending = (c: LiveCommand | undefined) => !!c && (c.state === "sending" || c.state === "sent");

// --------------------------------------------------------------------------- //
// store
// --------------------------------------------------------------------------- //

let live = new Map<string, LiveCommand>(); // newest command per node
const listeners = new Set<() => void>();
/** results that arrived (WebSocket) before the 202 told us the command id */
const early = new Map<string, WsEvent>();
const waiters = new Map<string, Array<(c: LiveCommand) => void>>(); // node id -> settle callbacks
const timers = new Map<string, number[]>(); // node id -> poll interval + timeout
let queryClient: QueryClient | null = null;

function emit() {
  for (const l of listeners) l();
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}

function put(next: LiveCommand) {
  live = new Map(live).set(next.nodeId, next);
  emit();
}

function clearTimers(nodeId: string) {
  for (const id of timers.get(nodeId) ?? []) window.clearInterval(id);
  timers.delete(nodeId);
}

function refresh(nodeId: string) {
  queryClient?.invalidateQueries({ queryKey: ["commands", nodeId] });
  queryClient?.invalidateQueries({ queryKey: ["nodes"] });
  // the device publishes its new status (valve, alarm) right after the result: fetch it too
  window.setTimeout(() => queryClient?.invalidateQueries({ queryKey: ["nodes"] }), 1500);
}

function settle(nodeId: string, patch: Partial<LiveCommand>) {
  const cur = live.get(nodeId);
  if (!cur || !isPending(cur)) return;
  const done: LiveCommand = { ...cur, ...patch, settledAt: Date.now() };
  clearTimers(nodeId);
  put(done);
  refresh(nodeId);
  const ws = waiters.get(nodeId) ?? [];
  waiters.delete(nodeId);
  for (const w of ws) w(done);
}

/** Result from the WebSocket (`command_result`) or the polled list. */
function applyResult(nodeId: string, commandId: string, status: string | undefined, detail: string | null) {
  const cur = live.get(nodeId);
  if (!cur || cur.commandId !== commandId || !isPending(cur)) return false;
  if (status !== "accepted" && status !== "rejected" && status !== "timeout") return false;
  settle(nodeId, { state: status, detail });
  return true;
}

/** WebSocket `command_result` event (also for commands sent by someone else). */
export function applyCommandEvent(ev: WsEvent, qc?: QueryClient) {
  if (qc) queryClient = qc;
  if (!ev.node_id) return;
  const cur = live.get(ev.node_id);
  if (ev.command_id && cur?.state === "sending") early.set(ev.command_id, ev);
  else if (ev.command_id) applyResult(ev.node_id, ev.command_id, ev.status, ev.detail ?? null);
  refresh(ev.node_id);
}

export interface SendOptions {
  token: string | null;
  nodeId: string;
  command: NodeCommandName;
  qc: QueryClient;
}

/** Sends a command and resolves once it is settled (accepted / rejected / timeout / error). */
export function sendNodeCommand({ token, nodeId, command, qc }: SendOptions): Promise<LiveCommand> {
  queryClient = qc;
  clearTimers(nodeId);
  const startedAt = Date.now();
  put({ nodeId, command, state: "sending", commandId: null, detail: null, error: null, startedAt, settledAt: null });
  const result = new Promise<LiveCommand>((resolve) => {
    waiters.set(nodeId, [...(waiters.get(nodeId) ?? []), resolve]);
  });

  api
    .post<CommandAck>(`/api/v1/nodes/${encodeURIComponent(nodeId)}/commands`, token, { command })
    .then((ack) => {
      const cur = live.get(nodeId);
      if (!cur || cur.startedAt !== startedAt) return; // superseded
      put({ ...cur, state: "sent", commandId: ack.command_id });
      const ev = early.get(ack.command_id);
      if (ev) {
        early.delete(ack.command_id);
        if (applyResult(nodeId, ack.command_id, ev.status, ev.detail ?? null)) return;
      }
      const poll = window.setInterval(async () => {
        try {
          const list = await api.get<CommandRecord[]>(
            `/api/v1/nodes/${encodeURIComponent(nodeId)}/commands?limit=5`,
            token,
          );
          const hit = list.find((c) => c.command_id === ack.command_id);
          if (hit && hit.status !== "sent") applyResult(nodeId, ack.command_id, hit.status, hit.detail);
        } catch {
          /* keep waiting: the WebSocket or the timeout settles it */
        }
      }, POLL_MS);
      const timeout = window.setTimeout(() => {
        const now = live.get(nodeId);
        if (now?.commandId === ack.command_id) settle(nodeId, { state: "timeout" });
      }, COMMAND_TIMEOUT_MS);
      timers.set(nodeId, [poll, timeout]);
    })
    .catch((e: unknown) => {
      const cur = live.get(nodeId);
      if (!cur || cur.startedAt !== startedAt) return;
      const status = e instanceof ApiError ? e.status : undefined;
      settle(nodeId, { state: "error", error: { status, message: (e as Error).message } });
    });

  return result;
}

/** Newest local command of a node (re-renders on change). */
export function useLiveCommand(nodeId: string): LiveCommand | undefined {
  return useSyncExternalStore(
    subscribe,
    () => live.get(nodeId),
    () => undefined,
  );
}

/** Every node's newest local command. */
export function useLiveCommands(): Map<string, LiveCommand> {
  return useSyncExternalStore(
    subscribe,
    () => live,
    () => live,
  );
}

/** none: never sent; pending: waiting for the device; rejected also covers a send the hub refused. */
export type CommandOutcome = "none" | "pending" | "ok" | "rejected" | "timeout";

/** Newest known result of a node's last command: this browser's live command when it is the
 *  newer one, else the hub's `last_command`. */
export function lastCommandOutcome(
  node: { last_command?: CommandRecord | null },
  live: LiveCommand | undefined,
): { outcome: CommandOutcome; command: string | null } {
  const rec = node.last_command;
  if (live && (!rec || live.startedAt >= parseTs(rec.sent_ts) - 1000)) {
    const outcome: CommandOutcome =
      live.state === "sending" || live.state === "sent"
        ? "pending"
        : live.state === "accepted"
          ? "ok"
          : live.state === "timeout"
            ? "timeout"
            : "rejected";
    return { outcome, command: live.command };
  }
  if (!rec) return { outcome: "none", command: null };
  const outcome: CommandOutcome =
    rec.status === "sent" ? "pending" : rec.status === "accepted" ? "ok" : rec.status === "timeout" ? "timeout" : "rejected";
  return { outcome, command: rec.command };
}

// --------------------------------------------------------------------------- //
// labels
// --------------------------------------------------------------------------- //

/** Firmware / hub result token (self_test, sensor_wet, ...) -> words; unknown tokens as text. */
export const commandDetailLabel = (detail: string, t: TFn) => tokenLabel(t, "cmddetail", detail);

/** Short command name: "Alarm test", "Valve closing", ... */
export const commandName = (command: string, t: TFn) => tokenLabel(t, "cmdname", command);

/** Why the hub refused to send (HTTP status of the POST). */
export function commandErrorLabel(err: { status?: number; message: string }, t: TFn): string {
  switch (err.status) {
    case 409:
      return t("nodecmd.err409");
    case 429:
      return t("nodecmd.err429");
    case 422:
      return t("nodecmd.err422");
    case 403:
      return t("nodecmd.err403");
    case 404:
      return t("nodecmd.err404");
    case 503:
      return t("nodecmd.err503");
    default:
      return err.message || t("error.network");
  }
}
