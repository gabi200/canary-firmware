/**
 * Editable floor plan of the room manager: rooms drawn at their building position (metres) on a
 * 0.5 m grid. Drag a room to move it (snaps to 0.5 m, saved on drop); a focused room moves by
 * 0.5 m with the arrow keys (1 m with Shift). Enter / Space or a click selects it. A click on an
 * empty spot asks for a new room there (`onEmptyClick`).
 * The scale is fixed (no rescaling while dragging, unlike the hazard map).
 */
import { useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";

import type { AdminZoneNode } from "../../api/types";
import { useT } from "../../i18n";
import { fmtNumber } from "../../lib/format";
import { zoneKindNote } from "../../lib/labels";
import { textWidth } from "../../lib/labelPlace";

/** SVG units per metre */
const U = 40;
/** room card footprint (metres) */
export const CARD_W = 3;
export const CARD_H = 1.6;
const SNAP = 0.5;

export type RoomStatus = "ok" | "attention" | "danger" | "offline" | "none";

export interface PlanRoom {
  id: string;
  label: string;
  kind: string;
  x: number;
  y: number;
  status: RoomStatus;
  nodes: AdminZoneNode[];
  /** outside the chosen apartment: drawn faded, still clickable (selecting it switches) */
  dim?: boolean;
}

interface Bounds {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

export const snap = (v: number) => Math.round(v / SNAP) * SNAP;

/** The room name on one line at the largest font (15 down to 12 px) that fits the card, else
 *  on two lines split at a space ("Centrală / termică", 10 to 13 px); one ellipsis-cut line when
 *  even that does not fit. */
function fitLabel(name: string, maxW: number): { lines: string[]; size: number } {
  const sizeFor = (text: string, max: number) => Math.min(max, Math.floor((15 * maxW) / textWidth(text, 15, 800)));
  const one = sizeFor(name, 15);
  if (one >= 12) return { lines: [name], size: one };
  const words = name.split(" ");
  let best: { lines: string[]; size: number } | null = null;
  for (let i = 1; i < words.length; i++) {
    const lines = [words.slice(0, i).join(" "), words.slice(i).join(" ")];
    const size = Math.min(sizeFor(lines[0], 13), sizeFor(lines[1], 13));
    if (size >= 10 && (!best || size > best.size)) best = { lines, size };
  }
  if (best) return best;
  let text = name;
  while (text.length > 1 && textWidth(`${text}…`, 10, 800) > maxW) text = text.slice(0, -1);
  return { lines: [text === name ? name : `${text.trimEnd()}…`], size: 10 };
}

function boundsOf(rooms: PlanRoom[]): Bounds {
  const xs = rooms.map((r) => r.x);
  const ys = rooms.map((r) => r.y);
  return {
    minX: Math.floor(Math.min(0, ...xs) - CARD_W / 2 - 0.5),
    minY: Math.floor(Math.min(0, ...ys) - CARD_H / 2 - 0.5),
    maxX: Math.ceil(Math.max(10, ...xs) + CARD_W / 2 + 2),
    maxY: Math.ceil(Math.max(6, ...ys) + CARD_H / 2 + 2),
  };
}

const NODE_COLOR: Record<string, string> = { ok: "#2ea043", attention: "#d29922", danger: "#f85149" };

interface Props {
  rooms: PlanRoom[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  /** a drag ended on a new position (snapped) */
  onMove: (id: string, x: number, y: number) => void;
  /** keyboard step (the parent saves it after a short pause) */
  onNudge: (id: string, x: number, y: number) => void;
  /** a click on an empty spot of the grid (snapped metres) */
  onEmptyClick?: (x: number, y: number) => void;
}

interface Drag {
  id: string;
  pointerId: number;
  startX: number; // pointer, metres
  startY: number;
  roomX: number;
  roomY: number;
  bounds: Bounds;
  moved: boolean;
}

export function RoomPlan({ rooms, selectedId, onSelect, onMove, onNudge, onEmptyClick }: Props) {
  const { t, lang } = useT();
  const svg = useRef<SVGSVGElement>(null);
  const [drag, setDrag] = useState<Drag | null>(null);
  const [dragPos, setDragPos] = useState<{ x: number; y: number } | null>(null);

  const live = useMemo(() => boundsOf(rooms), [rooms]);
  // frozen while dragging so the plan does not rescale under the pointer
  const b = drag?.bounds ?? live;
  const w = b.maxX - b.minX;
  const h = b.maxY - b.minY;
  const num = (v: number) => fmtNumber(v, lang, 1, true);
  const step = w > 30 ? 2 : 1;

  const toMetres = (clientX: number, clientY: number) => {
    const m = svg.current?.getScreenCTM();
    if (!m) return null;
    const p = new DOMPoint(clientX, clientY).matrixTransform(m.inverse());
    return { x: p.x / U, y: p.y / U };
  };

  const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

  const onPointerDown = (e: PointerEvent<SVGGElement>, r: PlanRoom) => {
    if (e.button !== 0) return;
    const p = toMetres(e.clientX, e.clientY);
    if (!p) return;
    e.preventDefault();
    (e.currentTarget as SVGGElement).focus({ preventScroll: true });
    svg.current?.setPointerCapture(e.pointerId);
    onSelect(r.id);
    setDrag({ id: r.id, pointerId: e.pointerId, startX: p.x, startY: p.y, roomX: r.x, roomY: r.y, bounds: live, moved: false });
    setDragPos({ x: r.x, y: r.y });
  };

  const onPointerMove = (e: PointerEvent<SVGSVGElement>) => {
    if (!drag || e.pointerId !== drag.pointerId) return;
    const p = toMetres(e.clientX, e.clientY);
    if (!p) return;
    const bb = drag.bounds;
    const x = clamp(snap(drag.roomX + p.x - drag.startX), bb.minX + CARD_W / 2, bb.maxX - CARD_W / 2);
    const y = clamp(snap(drag.roomY + p.y - drag.startY), bb.minY + CARD_H / 2, bb.maxY - CARD_H / 2);
    if (!drag.moved && Math.hypot(p.x - drag.startX, p.y - drag.startY) > 0.15) setDrag({ ...drag, moved: true });
    if (!dragPos || dragPos.x !== x || dragPos.y !== y) setDragPos({ x, y });
  };

  const endDrag = (e: PointerEvent<SVGSVGElement>, commit: boolean) => {
    if (!drag || e.pointerId !== drag.pointerId) return;
    svg.current?.releasePointerCapture?.(e.pointerId);
    if (commit && dragPos && (dragPos.x !== drag.roomX || dragPos.y !== drag.roomY)) {
      onMove(drag.id, dragPos.x, dragPos.y);
    }
    setDrag(null);
    setDragPos(null);
  };

  const onKeyDown = (e: KeyboardEvent<SVGGElement>, r: PlanRoom) => {
    const d = e.shiftKey ? 1 : SNAP;
    const moves: Record<string, [number, number]> = {
      ArrowLeft: [-d, 0],
      ArrowRight: [d, 0],
      ArrowUp: [0, -d],
      ArrowDown: [0, d],
    };
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      onSelect(r.id);
    } else if (moves[e.key]) {
      e.preventDefault();
      const [dx, dy] = moves[e.key];
      onSelect(r.id);
      onNudge(r.id, snap(r.x + dx), snap(r.y + dy));
    }
  };

  const lines = [];
  for (let x = b.minX; x <= b.maxX + 1e-9; x += SNAP) {
    const major = Math.abs(x - Math.round(x)) < 1e-9;
    lines.push(<line key={`x${x}`} x1={x * U} x2={x * U} y1={b.minY * U} y2={b.maxY * U} className={major ? "rp-grid major" : "rp-grid"} />);
  }
  for (let y = b.minY; y <= b.maxY + 1e-9; y += SNAP) {
    const major = Math.abs(y - Math.round(y)) < 1e-9;
    lines.push(<line key={`y${y}`} y1={y * U} y2={y * U} x1={b.minX * U} x2={b.maxX * U} className={major ? "rp-grid major" : "rp-grid"} />);
  }
  const labels = [];
  for (let x = Math.ceil(b.minX + 1); x < b.maxX; x += 1) {
    if (x % step) continue;
    labels.push(
      <text key={`lx${x}`} x={x * U} y={b.minY * U + 14} className="rp-axis" textAnchor="middle">
        {fmtNumber(x, lang, 0)}
      </text>,
    );
  }
  for (let y = Math.ceil(b.minY + 1); y < b.maxY; y += 1) {
    if (y % step) continue;
    labels.push(
      <text key={`ly${y}`} x={b.minX * U + 6} y={y * U + 4} className="rp-axis">
        {fmtNumber(y, lang, 0)}
      </text>,
    );
  }

  // selected (or dragged) room drawn last, on top
  const order = [...rooms].sort((a, c) => Number(a.id === selectedId) - Number(c.id === selectedId));
  const W = CARD_W * U;
  const H = CARD_H * U;

  return (
    <div className="rp-wrap">
      <svg
        ref={svg}
        className={`room-plan ${drag?.moved ? "dragging" : ""}`}
        viewBox={`${b.minX * U} ${b.minY * U} ${w * U} ${h * U}`}
        style={{ minWidth: Math.min(w * U, 1400) * 0.7 }}
        role="group"
        aria-label={t("rooms.planAria")}
        onPointerMove={onPointerMove}
        onPointerUp={(e) => endDrag(e, true)}
        onPointerCancel={(e) => endDrag(e, false)}
      >
        <rect
          x={b.minX * U}
          y={b.minY * U}
          width={w * U}
          height={h * U}
          className={`rp-bg ${onEmptyClick ? "addable" : ""}`}
          onClick={(e) => {
            const p = onEmptyClick && toMetres(e.clientX, e.clientY);
            if (p) onEmptyClick(snap(p.x), snap(p.y));
          }}
        >
          {onEmptyClick && <title>{t("rooms.clickToAdd")}</title>}
        </rect>
        {lines}
        <line x1={0} x2={0} y1={b.minY * U} y2={b.maxY * U} className="rp-origin" />
        <line y1={0} y2={0} x1={b.minX * U} x2={b.maxX * U} className="rp-origin" />
        {labels}
        <text x={b.maxX * U - 8} y={b.minY * U + 14} className="rp-axis" textAnchor="end">
          m
        </text>

        {order.map((r) => {
          const pos = drag?.id === r.id && dragPos ? dragPos : r;
          const sel = r.id === selectedId;
          const name = r.label || r.id;
          const fit = fitLabel(name, W - 23);
          const aria = t("rooms.roomAria", { name, x: num(pos.x), y: num(pos.y) });
          return (
            <g
              key={r.id}
              className={`rp-room st-${r.status} ${sel ? "sel" : ""} ${r.dim ? "dim" : ""} ${drag?.id === r.id ? "grabbed" : ""}`}
              transform={`translate(${pos.x * U} ${pos.y * U})`}
              tabIndex={0}
              role="button"
              aria-pressed={sel}
              aria-label={aria}
              onPointerDown={(e) => onPointerDown(e, r)}
              onKeyDown={(e) => onKeyDown(e, r)}
            >
              <title>{aria}</title>
              <rect className="rp-ring" x={-W / 2 - 4} y={-H / 2 - 4} width={W + 8} height={H + 8} rx={11} />
              <rect className="rp-card" x={-W / 2} y={-H / 2} width={W} height={H} rx={8} />
              <rect className="rp-bar" x={-W / 2} y={-H / 2} width={7} height={H} rx={3.5} />
              {fit.lines.map((line, i) => (
                <text key={i} className="rp-label" x={-W / 2 + 15} y={-H / 2 + 20 + i * (fit.size + 2)} style={{ fontSize: fit.size }}>
                  {line}
                </text>
              ))}
              {fit.lines.length === 1 && (
                <text className="rp-sub" x={-W / 2 + 15} y={-H / 2 + 39}>
                  {zoneKindNote(name, r.kind, t)}
                </text>
              )}
              {r.nodes.slice(0, 7).map((n, i) => (
                <circle
                  key={n.node_id}
                  cx={-W / 2 + 21 + i * 15}
                  cy={H / 2 - 13}
                  r={5}
                  fill={n.online ? (NODE_COLOR[n.status] ?? "#8b98a8") : "#0f1419"}
                  stroke={n.online ? "none" : "#8b98a8"}
                  strokeWidth={1.5}
                />
              ))}
              {r.nodes.length > 7 && (
                <text className="rp-sub" x={-W / 2 + 21 + 7 * 15} y={H / 2 - 9}>
                  +{r.nodes.length - 7}
                </text>
              )}
              {(sel || drag?.id === r.id) && (
                <text className="rp-coords" x={0} y={H / 2 + 17} textAnchor="middle">
                  x {num(pos.x)} · y {num(pos.y)} m
                </text>
              )}
            </g>
          );
        })}
      </svg>
    </div>
  );
}
