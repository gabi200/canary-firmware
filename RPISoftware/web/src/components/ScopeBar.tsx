/**
 * Floor / apartment / room chooser pinned under the top bar (Sensors page, every Administration
 * tab): the floors and the whole building; below them the apartments and common areas of the
 * chosen floor (and "whole floor"); below those the rooms of the chosen apartment. Every chip shows its sensor count and the worst analysis status of its
 * online sensors. The choice is shared and remembered (lib/scope).
 */
import { useEffect, useRef, type ReactNode } from "react";

import { useNodes, useSummary } from "../api/hooks";
import type { AnalysisLevel, NodeOut } from "../api/types";
import { pluralCategory, useT } from "../i18n";
import { fmtNumber } from "../lib/format";
import { levelLabel } from "../lib/labels";
import { useScope } from "../lib/scope";
import { BathIcon, BedIcon, DoorIcon, FlameIcon, PotIcon, SofaIcon, StairsIcon } from "./Icons";

const RANK: Record<string, number> = { ok: 1, attention: 2, danger: 3 };

/** Room kind -> line icon (scope chips, floor plan tiles). */
export const KIND_ICON: Record<string, typeof BedIcon> = {
  kitchen: PotIcon,
  bathroom: BathIcon,
  bedroom: BedIcon,
  living_room: SofaIcon,
  hallway: DoorIcon,
  stairwell: StairsIcon,
  boiler: FlameIcon,
};

/** Worst status of the online sensors (summary first, the node's own analysis otherwise);
 *  unknown when none is online. */
function worst(nodes: NodeOut[], status: Map<string, string>): AnalysisLevel {
  let w: AnalysisLevel = "unknown";
  for (const n of nodes) {
    if (!n.online) continue;
    const s = (status.get(n.id) ?? n.analysis?.status) as AnalysisLevel;
    if ((RANK[s] ?? 0) > (RANK[w] ?? 0)) w = s;
  }
  return w;
}

interface ChipProps {
  on: boolean;
  label: string;
  /** null while the sensors load */
  nodes: NodeOut[] | null;
  status: Map<string, string>;
  icon?: ReactNode;
  onClick: () => void;
}

function Chip({ on, label, nodes, status, icon, onClick }: ChipProps) {
  const { t, lang } = useT();
  const level = nodes ? worst(nodes, status) : "unknown";
  const n = nodes?.length ?? 0;
  return (
    <button type="button" className={`scope-chip ${on ? "on" : ""}`} aria-pressed={on} onClick={onClick}>
      <span className={`lvl ${level}`} aria-hidden="true" />
      {icon}
      <span>{label}</span>
      {nodes && (
        <>
          <span className="seg-n" aria-hidden="true">
            {fmtNumber(n, lang, 0)}
          </span>
          <span className="sr-only">
            , {t(`rooms.sensorCount.${pluralCategory(lang, n)}`, { n: fmtNumber(n, lang, 0) })}, {levelLabel(level, t)}
          </span>
        </>
      )}
    </button>
  );
}

/** `rooms: false` hides the room row (accounts belong to apartments, not rooms). */
export function ScopeBar({ rooms = true }: { rooms?: boolean }) {
  const { t } = useT();
  const sc = useScope();
  const nodes = useNodes();
  const summary = useSummary();
  const bar = useRef<HTMLDivElement>(null);
  const shown = sc.ready && sc.units.length > 0;
  // Keep the chosen chips in sight (sideways only: scrollIntoView would also scroll the page
  // back to where the sticky bar sits unstuck). "All rooms" is no choice, so it moves nothing.
  useEffect(() => {
    const el = bar.current;
    if (!el) return;
    const on = [...el.querySelectorAll<HTMLElement>(".scope-chip.on")];
    if (el.scrollWidth <= el.clientWidth) {
      // wrapped rows (wide screens): each row on its own
      for (const chip of on) {
        const row = chip.parentElement;
        if (!row) continue;
        const c = chip.getBoundingClientRect();
        const r = row.getBoundingClientRect();
        if (c.left < r.left) row.scrollLeft -= r.left - c.left + 20;
        else if (c.right > r.right) row.scrollLeft += c.right - r.right + 20;
      }
      return;
    }
    // phones: one line that scrolls sideways. Show the chosen floor through the most specific
    // choice when they fit, else the most specific one; the left edge always falls in the gap
    // before a chip, never through one.
    // "Whole floor" and "All rooms" are no choice of their own
    const chosen = on.slice(0, sc.scope.unit === "all" ? 1 : sc.scope.room === "all" ? 2 : 3);
    if (!chosen.length) return;
    const chips = [...el.querySelectorAll<HTMLElement>(".scope-chip")];
    const css = getComputedStyle(el);
    const padL = parseFloat(css.paddingLeft) || 0;
    const padR = parseFloat(css.paddingRight) || 0;
    const origin = el.getBoundingClientRect().left - el.scrollLeft;
    const left = (c: HTMLElement) => c.getBoundingClientRect().left - origin;
    const right = (c: HTMLElement) => c.getBoundingClientRect().right - origin;
    /** scroll position that puts `c` at the left edge, with the gap before it (or the padding) */
    const startAt = (c: HTMLElement) => {
      const i = chips.indexOf(c);
      const gap = i > 0 ? left(c) - right(chips[i - 1]) : padL;
      return Math.max(0, left(c) - Math.min(padL, gap));
    };
    const last = chosen[chosen.length - 1];
    const need = right(last) + padR - el.clientWidth;
    let start = chosen.map(startAt).find((s) => s >= need);
    if (start === undefined) {
      // the most specific chip alone: the first chip boundary at or after the needed offset
      const own = startAt(last);
      start = chips.map(startAt).find((s) => s >= need && s <= own) ?? own;
    }
    el.scrollLeft = Math.min(start, el.scrollWidth - el.clientWidth);
  }, [shown, sc.scope.floor, sc.scope.unit, sc.scope.room, !!nodes.data]);
  if (!shown) return null;

  const status = new Map<string, string>();
  for (const z of summary.data?.zones ?? []) for (const n of z.nodes) status.set(n.node_id, n.status);
  const unitOf = new Map(sc.rooms.map((r) => [r.id, r.unitId]));
  const floorOf = new Map(sc.rooms.map((r) => [r.id, r.floorId]));
  const of = (keep: (n: NodeOut) => boolean) => (nodes.data ? nodes.data.filter(keep) : null);
  const { unit, room } = sc.scope;
  const floor = sc.floor?.id ?? "all";
  const unitRooms = sc.rooms.filter((r) => r.unitId === unit);
  const floorUnits = floor === "all" ? sc.units : sc.units.filter((u) => u.floorId === floor);

  return (
    <div className="scope-bar" ref={bar} role="region" aria-label={t("scope.aria")}>
      <div className="scope-row">
        <span className="scope-row-label" id="scope-floor-label">
          {t("scope.floorRow")}
        </span>
        <div className="scope-chips" role="group" aria-labelledby="scope-floor-label">
          {sc.floors.map((f) => (
            <Chip
              key={f.id}
              on={floor === f.id}
              label={f.label}
              nodes={of((n) => floorOf.get(n.zone_id) === f.id)}
              status={status}
              onClick={() => sc.setScope({ unit: "all", room: "all", floor: f.id })}
            />
          ))}
          <Chip
            on={unit === "all" && floor === "all"}
            label={t("scope.building")}
            nodes={of(() => true)}
            status={status}
            onClick={() => sc.setScope({ unit: "all", room: "all", floor: "all" })}
          />
        </div>
      </div>
      <div className="scope-row">
        <span className="scope-row-label" id="scope-unit-label">
          {t("scope.unitRow")}
        </span>
        <div className="scope-chips" role="group" aria-labelledby="scope-unit-label">
          {floorUnits.map((u) => (
            <Chip
              key={u.id}
              on={unit === u.id}
              label={u.label}
              nodes={of((n) => unitOf.get(n.zone_id) === u.id)}
              status={status}
              onClick={() => sc.setScope({ unit: u.id, room: "all" })}
            />
          ))}
          {floor !== "all" && (
            <Chip
              on={unit === "all"}
              label={t("scope.wholeFloor")}
              nodes={of((n) => floorOf.get(n.zone_id) === floor)}
              status={status}
              onClick={() => sc.setScope({ unit: "all", room: "all", floor })}
            />
          )}
        </div>
      </div>
      {rooms && unit !== "all" && (
        <div className="scope-row">
          <span className="scope-row-label" id="scope-room-label">
            {t("scope.roomRow")}
          </span>
          <div className="scope-chips" role="group" aria-labelledby="scope-room-label">
            <Chip
              on={room === "all"}
              label={t("scope.allRooms")}
              nodes={of((n) => unitOf.get(n.zone_id) === unit)}
              status={status}
              onClick={() => sc.setScope({ unit, room: "all" })}
            />
            {unitRooms.map((r) => {
              const KindIcon = KIND_ICON[r.kind];
              return (
                <Chip
                  key={r.id}
                  on={room === r.id}
                  label={r.label}
                  icon={KindIcon && <KindIcon />}
                  nodes={of((n) => n.zone_id === r.id)}
                  status={status}
                  onClick={() => sc.setScope({ unit, room: r.id })}
                />
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
