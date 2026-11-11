/**
 * Compact state vocabulary shared by the manager's matrices and grids (device health, room normal,
 * motion): a small box with a drawn mark, coloured by one tone, and a one-line legend. The box
 * carries the full original sentence as tooltip and accessible name, so compacting never drops a fact.
 * Styles: "compact state cells" in styles.css.
 */
import type { MouseEvent, ReactNode } from "react";
import { Link } from "react-router-dom";

/** danger / attention: state colours; motion: the accent (as the motion pill); quiet: fine, no emphasis;
 *  unknown: not known yet or not measurable; none: no data at all (dashed). */
export type CellTone = "danger" | "attention" | "unknown" | "quiet" | "motion" | "none";

interface StateCellProps {
  tone: CellTone;
  /** the full sentence: tooltip and accessible name */
  label: string;
  children: ReactNode;
  /** makes the cell a link (keyboard reachable) */
  to?: string;
  onNavigate?: () => void;
  /** marks simulated seed data with a small ring in the corner */
  seed?: boolean;
  /** shows the cell's sentence where the grid prints it (hover, keyboard focus, tap); without it the
   *  sentence stays in the tooltip / accessible name only */
  onPreview?: (label: string) => void;
  /** the grid currently prints this cell's sentence */
  previewed?: boolean;
}

/** The pointer that pressed last: a first touch tap on a link shows the sentence instead of leaving. */
let lastPointer = "mouse";

export function StateCell({ tone, label, children, to, onNavigate, seed, onPreview, previewed }: StateCellProps) {
  const common = {
    className: "scell",
    "data-tone": tone,
    "data-seed": seed ? "true" : undefined,
    "data-previewed": previewed ? "true" : undefined,
    title: label,
    "aria-label": label,
    ...(onPreview
      ? {
          onPointerEnter: (e: { pointerType: string }) => {
            if (e.pointerType !== "touch") onPreview(label);
          },
          onFocus: () => onPreview(label),
          onPointerDown: (e: { pointerType: string }) => {
            lastPointer = e.pointerType;
          },
        }
      : {}),
  };
  if (to) {
    const click = (e: MouseEvent<HTMLAnchorElement>) => {
      if (onPreview && lastPointer === "touch" && !previewed) {
        e.preventDefault();
        onPreview(label);
        return;
      }
      onNavigate?.();
    };
    return (
      <Link to={to} onClick={click} {...common}>
        {children}
      </Link>
    );
  }
  return (
    <span role="img" tabIndex={onPreview ? 0 : undefined} {...common}>
      {children}
    </span>
  );
}

/** The bare mark of a state (no box), for legends. */
export function StateMark({ tone, seed, children }: { tone: CellTone; seed?: boolean; children?: ReactNode }) {
  return (
    <span className="smark" data-tone={tone} data-seed={seed ? "true" : undefined} aria-hidden="true">
      {children}
    </span>
  );
}

export interface LegendItem {
  key: string;
  mark: ReactNode;
  text: ReactNode;
}

export function StateLegend({ items, stacked }: { items: LegendItem[]; stacked?: boolean }) {
  return (
    <ul className={stacked ? "slegend stacked" : "slegend"}>
      {items.map((i) => (
        <li key={i.key}>
          {i.mark}
          <span>{i.text}</span>
        </li>
      ))}
    </ul>
  );
}
