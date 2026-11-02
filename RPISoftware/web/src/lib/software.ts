/**
 * Hub software updates (GET /hub/software) in plain words: what blocks an update and one status
 * line per Pi. Returns i18n keys; the Hub tab translates them.
 */
import type { MsgKey } from "../i18n";
import type { SoftwareNode, SoftwareOverview } from "../api/types";
import type { LineTone } from "./cluster";

const BUSY = new Set(["updating", "rolling_back"]);

export function isBusy(o: SoftwareOverview): boolean {
  return o.rollout?.outcome === "running" || o.nodes.some((n) => !!n.status && BUSY.has(n.status.state));
}

export function targetCommit(o: SoftwareOverview): string | null {
  return o.github.head?.sha ?? null;
}

function atTarget(n: SoftwareNode, target: string | null): boolean {
  return !!target && n.status?.commit?.sha === target;
}

/** Why this Pi cannot be updated on its own (precedence as listed), or null. */
function ownBlocker(n: SoftwareNode): MsgKey | null {
  if (!n.reachable || !n.status) return "sw.block.unreachable";
  if (n.status.state === "failed") return "sw.block.failed";
  if (n.status.dirty) return "sw.block.dirty";
  if (n.status.ahead > 0) return "sw.block.ahead";
  if (n.status.branch !== "main") return "sw.block.notMain";
  return null;
}

function common(o: SoftwareOverview): MsgKey | null {
  if (!o.configured) return "sw.block.notConfigured";
  if (!targetCommit(o)) return "sw.block.noHead";
  if (isBusy(o)) return "sw.block.busy";
  return null;
}

export function allBlocker(o: SoftwareOverview): MsgKey | null {
  const first = common(o);
  if (first) return first;
  for (const n of o.nodes) {
    const own = ownBlocker(n);
    if (own) return own;
  }
  return o.nodes.every((n) => atTarget(n, targetCommit(o))) ? "sw.block.upToDate" : null;
}

export function piBlocker(o: SoftwareOverview, name: string): MsgKey | null {
  const first = common(o);
  if (first) return first;
  const n = o.nodes.find((x) => x.name === name);
  if (!n) return "sw.block.unreachable";
  return ownBlocker(n) ?? (atTarget(n, targetCommit(o)) ? "sw.block.upToDate" : null);
}

export interface PiLine {
  tone: LineTone;
  key: MsgKey;
  vars?: Record<string, string | number>;
}

export function piLine(n: SoftwareNode): PiLine {
  const s = n.status;
  if (!n.reachable || !s) return { tone: "danger", key: "sw.pi.unreachable" };
  if (s.state === "failed") return { tone: "danger", key: "sw.pi.failed" };
  if (s.state === "rolled_back") return { tone: "attention", key: "sw.pi.rolledBack" };
  if (s.state === "updating") return { tone: "info", key: "sw.pi.updating", vars: { step: s.step ?? "" } };
  if (s.state === "rolling_back") return { tone: "attention", key: "sw.pi.rollingBack" };
  if (s.dirty) return { tone: "attention", key: "sw.block.dirty" };
  if (s.ahead > 0) return { tone: "attention", key: "sw.block.ahead" };
  if (s.behind > 0) return { tone: "attention", key: "sw.pi.behind", vars: { n: s.behind } };
  return { tone: "ok", key: "sw.pi.upToDate" };
}

export const shortSha = (sha: string | null | undefined) => (sha ?? "").slice(0, 7);
