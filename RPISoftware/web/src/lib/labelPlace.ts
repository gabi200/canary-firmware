/**
 * Greedy collision-free label placement for the map overlays: each label tries candidate
 * positions around its anchor (in its preferred order) and takes the first one that stays inside
 * its allowed box and touches no placed label, obstacle box or anchor circle.
 */
export interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Circle {
  x: number;
  y: number;
  r: number;
  /** the anchor's own label may touch it */
  owner?: string;
}

export type Side =
  | "right"
  | "left"
  | "above"
  | "below"
  | "aboveRight"
  | "belowRight"
  | "aboveLeft"
  | "belowLeft";

export interface LabelRequest {
  id: string;
  ax: number;
  ay: number;
  /** anchor radius (label keeps clear of it) */
  r: number;
  w: number;
  h: number;
  /** the label must fit entirely inside this box */
  within: Box;
  sides: Side[];
}

const GAP = 3;
const D = Math.SQRT1_2;

function candidate(side: Side, q: LabelRequest): Box {
  const { ax, ay, w, h } = q;
  const d = q.r + GAP;
  switch (side) {
    case "right":
      return { x: ax + d, y: ay - h / 2, w, h };
    case "left":
      return { x: ax - d - w, y: ay - h / 2, w, h };
    case "above":
      return { x: ax - w / 2, y: ay - d - h, w, h };
    case "below":
      return { x: ax - w / 2, y: ay + d, w, h };
    case "aboveRight":
      return { x: ax + d * D, y: ay - d * D - h, w, h };
    case "belowRight":
      return { x: ax + d * D, y: ay + d * D, w, h };
    case "aboveLeft":
      return { x: ax - d * D - w, y: ay - d * D - h, w, h };
    case "belowLeft":
      return { x: ax - d * D - w, y: ay + d * D, w, h };
  }
}

export const boxesHit = (a: Box, b: Box) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

const contains = (outer: Box, b: Box) =>
  b.x >= outer.x && b.y >= outer.y && b.x + b.w <= outer.x + outer.w && b.y + b.h <= outer.y + outer.h;

export function circleHits(b: Box, c: Circle): boolean {
  const px = Math.max(b.x, Math.min(c.x, b.x + b.w));
  const py = Math.max(b.y, Math.min(c.y, b.y + b.h));
  return (px - c.x) ** 2 + (py - c.y) ** 2 < c.r ** 2;
}

/** First candidate of `q` that fits; null when none does. */
export function placeLabel(q: LabelRequest, placed: Box[], obstacles: Box[], circles: Circle[]): Box | null {
  for (const side of q.sides) {
    const b = candidate(side, q);
    if (!contains(q.within, b)) continue;
    if (placed.some((p) => boxesHit(p, b)) || obstacles.some((o) => boxesHit(o, b))) continue;
    if (circles.some((c) => c.owner !== q.id && circleHits(b, c))) continue;
    return b;
  }
  return null;
}

let ctx: CanvasRenderingContext2D | null | undefined;

/** Rendered width of a label (canvas metrics with the page font; estimate without a canvas). */
export function textWidth(text: string, fontSize: number, weight = 700): number {
  if (ctx === undefined) {
    try {
      ctx = document.createElement("canvas").getContext("2d");
    } catch {
      ctx = null;
    }
  }
  if (!ctx) return text.length * fontSize * 0.68;
  const family = getComputedStyle(document.documentElement).fontFamily || "system-ui, sans-serif";
  ctx.font = `${weight} ${fontSize}px ${family}`;
  return ctx.measureText(text).width;
}
