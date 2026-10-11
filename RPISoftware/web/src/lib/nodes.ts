import type { AnalysisLevel, NodeOut } from "../api/types";

/** Value at a dotted path ("co.ppm") of a raw status document; undefined when absent. */
export function pick(doc: unknown, path: string): unknown {
  let cur = doc;
  for (const key of path.split(".")) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

export function pickNum(doc: unknown, path: string): number | null {
  const v = pick(doc, path);
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

/** Every leaf path of a document ("co.ppm", "wifi.rssi", ...); arrays count as leaves. */
export function leafPaths(value: unknown, prefix = ""): string[] {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return prefix ? [prefix] : [];
  }
  return Object.entries(value).flatMap(([k, v]) => leafPaths(v, prefix ? `${prefix}.${k}` : k));
}

/** Device-side state tokens (channel grading, leak sensor, alarm, valve) -> display level. */
export function stateLevel(state: unknown): AnalysisLevel {
  switch (state) {
    case "ok":
    case "dry":
    case "inactive":
    case "open":
      return "ok";
    case "warning":
    case "fault":
    case "silenced":
    case "timed_out":
    case "closed":
      return "attention";
    case "danger":
    case "wet":
    case "sounding":
      return "danger";
    default:
      return "unknown"; // warmup, uninitialized, missing
  }
}

export type Connectivity = "online" | "stale" | "offline";

/** Connectivity pill of a node (`state` is a token; label it with `conn.<state>`). */
export function connectivity(node: NodeOut): { level: AnalysisLevel; state: Connectivity } {
  if (!node.online) return { level: "attention", state: "offline" }; // connectivity, not a hazard
  if (node.analysis?.stale) return { level: "attention", state: "stale" };
  return { level: "ok", state: "online" };
}
