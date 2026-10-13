/**
 * The hub's Pis in plain words (GET /cluster). One Pi runs every role; with three Pis each one has
 * a home role (processing, web = the hub address, ai) and another Pi takes it over when it fails.
 * The status lines above the Hub tab's cards and the manager's warning banner come from here.
 */
import type { ClusterNode, ClusterStatus } from "../api/types";
import type { MsgKey, TFn } from "../i18n";
import { tokenLabel } from "./labels";

/** Roles GET /cluster answers (anyone else gets 403: don't ask). */
export function canSeeCluster(role: string | undefined): boolean {
  return role === "system_admin" || role === "hoa_manager" || role === "technician";
}

export type LineTone = "danger" | "attention" | "ok" | "info";

export interface StatusLine {
  tone: LineTone;
  text: string;
  sub?: string;
}

const RANK: Record<LineTone, number> = { danger: 0, attention: 1, ok: 2, info: 3 };

/** Card and chip order: the sensor pipeline, the front door, then AI. */
const ORDER = ["processing", "web", "ai"];
const rank = (name: string) => (ORDER.includes(name) ? ORDER.indexOf(name) : ORDER.length);

export const sortNodes = (nodes: ClusterNode[]) =>
  [...nodes].sort((a, b) => rank(a.home_role ?? a.name) - rank(b.home_role ?? b.name) || a.name.localeCompare(b.name));

export const sortRoles = (roles: string[]) => [...roles].sort((a, b) => rank(a) - rank(b));

/** "Processing Pi" / "Pi-ul de procesare" ("hub" in single mode); an unknown name as it is. */
export const piLabel = (name: string, t: TFn) => tokenLabel(t, "hub.pi", name);

/** Role chip: "Holds the hub address", "Processes sensor data", "Runs AI tasks". */
export const roleLabel = (role: string, t: TFn) => tokenLabel(t, "hub.role", role);

/** The alive Pi, other than `except`, that runs `role` now. */
export const runnerOf = (c: ClusterStatus, role: string, except?: ClusterNode) =>
  c.nodes.find((n) => n !== except && n.alive && n.roles.includes(role));

/** A role `n` runs away from its own Pi: taken over from a Pi that failed (or is not back yet). */
export const takenOver = (n: ClusterNode, role: string) => !!n.home_role && role !== n.home_role;

const AWAY: Record<string, MsgKey> = { processing: "hub.awayProcessing", web: "hub.awayWeb", ai: "hub.awayAi" };

/** Problems first (danger, then attention), then "all good", then notes. A down Pi says who took
 *  over its role; a role away from its alive home Pi says where it runs; no processing Pi is
 *  critical; AI on a Pi without a working AI HAT+ 2 means briefs come from the template. */
export function statusLines(c: ClusterStatus, t: TFn): StatusLine[] {
  const lines: StatusLine[] = [];
  const named = (n: ClusterNode) => (n.ip ? `${piLabel(n.name, t)} (${n.ip})` : piLabel(n.name, t));

  if (!c.processing_node) lines.push({ tone: "danger", text: t("hub.noProcessing"), sub: t("hub.noProcessingSub") });

  if (c.mode === "triple") {
    for (const n of sortNodes(c.nodes)) {
      const home = n.home_role;
      if (!n.alive) {
        const to = home ? runnerOf(c, home, n) : undefined;
        lines.push({
          tone: "attention",
          text: t("hub.nodeDown", { pi: named(n) }),
          sub: to && home ? t("hub.tookOver", { pi: piLabel(to.name, t), role: tokenLabel(t, "hub.roleObj", home) }) : undefined,
        });
      } else if (home && AWAY[home] && !n.roles.includes(home)) {
        const to = runnerOf(c, home, n);
        if (to) {
          lines.push({
            tone: "attention",
            text: t(AWAY[home], { to: piLabel(to.name, t), from: piLabel(n.name, t) }),
            sub: t("hub.awaySub"),
          });
        }
      }
    }
  }

  const ai = c.nodes.find((n) => n.name === c.ai_node);
  if (ai && !ai.accelerator) {
    lines.push({ tone: "info", text: t("hub.briefTemplate"), sub: t("hub.noHat", { pi: piLabel(ai.name, t) }) });
  } else if (ai?.accelerator && !(ai.alive && ai.accelerator.online)) {
    lines.push({ tone: "attention", text: t("hub.briefTemplate"), sub: t("hub.hatOffline", { pi: piLabel(ai.name, t) }) });
  }

  if (!lines.some((l) => l.tone === "danger" || l.tone === "attention")) {
    // the backend's verdict wins: never "all good" while it reports degraded
    if (c.degraded) lines.push({ tone: "attention", text: t("hub.degraded") });
    else if (c.mode === "triple") lines.push({ tone: "ok", text: t("hub.allGood") });
  }
  return lines.sort((a, b) => RANK[a.tone] - RANK[b.tone]);
}

/** The worst problem (the manager's banner); null when there is none. */
export function worstProblem(c: ClusterStatus, t: TFn): StatusLine | null {
  const top = statusLines(c, t)[0];
  return top && (top.tone === "danger" || top.tone === "attention") ? top : null;
}
