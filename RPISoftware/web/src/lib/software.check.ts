// ponytail: one runnable check for the software-update helpers (no test runner in this package):
//   node_modules/.bin/esbuild src/lib/software.check.ts --bundle --platform=node --format=esm \
//     --outfile=/tmp/sw.mjs && node /tmp/sw.mjs
import type { PiSoftwareStatus, SoftwareNode, SoftwareOverview } from "../api/types";
import { allBlocker, isBusy, piBlocker, piLine } from "./software";

const eq = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} != ${JSON.stringify(b)}`);
};
const HEAD = "b".repeat(40);
const OLD = "a".repeat(40);

function pi(name: string, over: Partial<PiSoftwareStatus> = {}, reachable = true): SoftwareNode {
  const status: PiSoftwareStatus = {
    node: name, commit: { sha: OLD, subject: "old", date: "2026-11-01T10:00:00Z" }, branch: "main", dirty: false,
    behind: 1, ahead: 0, state: "idle", step: null, target: null, previous: null, error: null, log: [],
    rollout: null, restart_needed: false, fetched_at: null, fetch_error: null, ...over,
  };
  return { name, ip: null, reachable, status: reachable ? status : null };
}

function overview(nodes: SoftwareNode[], over: Partial<SoftwareOverview> = {}): SoftwareOverview {
  return {
    configured: true, mode: "triple", incoming: [], rollout: null, nodes,
    github: { head: { sha: HEAD, subject: "new", date: "2026-11-02T10:00:00Z" }, fetched_at: null, fetch_error: null },
    ...over,
  };
}

const atHead = { commit: { sha: HEAD, subject: "new", date: "" }, behind: 0 };
eq(allBlocker(overview([pi("processing", atHead), pi("web", atHead)])), "sw.block.upToDate");
eq(allBlocker(overview([pi("processing"), pi("web", { state: "updating" })])), "sw.block.busy");
eq(allBlocker(overview([pi("processing"), pi("web", {}, false)])), "sw.block.unreachable");
eq(allBlocker(overview([pi("processing"), pi("web")], { configured: false })), "sw.block.notConfigured");
eq(allBlocker(overview([pi("processing"), pi("web")])), null);
const dirty = overview([pi("processing", { dirty: true }), pi("web")]);
eq(piBlocker(dirty, "processing"), "sw.block.dirty");
eq(piBlocker(dirty, "web"), null);
eq(allBlocker(dirty), "sw.block.dirty");
eq(piBlocker(overview([pi("processing", { ahead: 2 }), pi("web")]), "processing"), "sw.block.ahead");
eq(piBlocker(overview([pi("processing", atHead), pi("web")]), "processing"), "sw.block.upToDate");
eq(piLine(pi("web", { behind: 3 })), { tone: "attention", key: "sw.pi.behind", vars: { n: 3 } });
eq(piLine(pi("web", atHead)).key, "sw.pi.upToDate");
eq(piLine(pi("web", {}, false)).tone, "danger");
eq(piLine(pi("web", { state: "updating", step: "building" })), { tone: "info", key: "sw.pi.updating", vars: { step: "building" } });
eq(isBusy(overview([pi("web")], {
  rollout: { commit: HEAD, order: ["web"], results: { web: "waiting" }, current: null, outcome: "running", reason: null, started_at: "" },
})), true);
eq(isBusy(overview([pi("web")])), false);
console.log("software ok");
