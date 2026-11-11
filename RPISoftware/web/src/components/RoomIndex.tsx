/**
 * Rooms at a glance under the floor plan: every room of the shown floor(s) as one small button
 * (status, apartment, key reading, people), problems first. Search by room or apartment name,
 * filter to the rooms that need attention / have people / send no data. A click opens the same
 * room panel as the plan.
 */
import { useState } from "react";

import { useT } from "../i18n";
import { fmtNumber, natural } from "../lib/format";
import { type ZoneView, zoneStatusText } from "../lib/hazardMap";
import { prettyId } from "../lib/labels";
import { PersonIcon, SearchIcon } from "./Icons";
import { KIND_ICON } from "./ScopeBar";

type Filter = "all" | "problems" | "people" | "nodata";

const RANK: Record<string, number> = { danger: 3, attention: 2, ok: 1, unknown: 0 };
const needsLook = (z: ZoneView) => z.isSource || z.isAffected || z.level === "danger" || z.level === "attention";

/** lower case, no diacritics: "bucatarie" finds "Bucătărie" */
const fold = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();

interface Props {
  zones: ZoneView[];
  unitLabel: (unitId: string) => string;
  selectedId: string | null;
  onSelect: (zoneId: string) => void;
}

export function RoomIndex({ zones, unitLabel, selectedId, onSelect }: Props) {
  const { t, lang } = useT();
  const [q, setQ] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const name = (z: ZoneView) => z.placed.zone.label || prettyId(z.placed.zone.id);
  const unit = (z: ZoneView) => unitLabel(z.placed.zone.unit_id);

  const counts: Record<Filter, number> = {
    all: zones.length,
    problems: zones.filter(needsLook).length,
    people: zones.filter((z) => z.occupancy > 0).length,
    nodata: zones.filter((z) => z.level === "unknown").length,
  };
  const keep: Record<Filter, (z: ZoneView) => boolean> = {
    all: () => true,
    problems: needsLook,
    people: (z) => z.occupancy > 0,
    nodata: (z) => z.level === "unknown",
  };
  const needle = fold(q.trim());
  const shown = zones
    .filter(keep[filter])
    .filter((z) => !needle || fold(`${name(z)} ${unit(z)}`).includes(needle))
    .sort(
      (a, b) =>
        Number(b.isSource) - Number(a.isSource) ||
        (RANK[b.level] ?? 0) - (RANK[a.level] ?? 0) ||
        natural(unit(a), unit(b)) ||
        natural(name(a), name(b)),
    );
  const FILTERS: { id: Filter; label: string }[] = [
    { id: "all", label: t("ri.all") },
    { id: "problems", label: t("ri.problems") },
    { id: "people", label: t("ri.people") },
    { id: "nodata", label: t("ri.noData") },
  ];

  return (
    <section className="room-index" aria-labelledby="ri-title">
      <div className="ri-head">
        <h4 id="ri-title">{t("ri.title")}</h4>
        <label className="ri-search">
          <SearchIcon />
          <input
            className="input"
            type="search"
            value={q}
            placeholder={t("ri.search")}
            aria-label={t("ri.search")}
            onChange={(e) => setQ(e.target.value)}
          />
        </label>
        <div className="seg" role="group" aria-label={t("ri.filterAria")}>
          {FILTERS.map((f) => (
            <button key={f.id} type="button" className={filter === f.id ? "active" : ""} aria-pressed={filter === f.id} onClick={() => setFilter(f.id)}>
              {f.label} <span className="seg-n">{fmtNumber(counts[f.id], lang, 0)}</span>
            </button>
          ))}
        </div>
      </div>
      {shown.length === 0 ? (
        <div className="muted small">{t("ri.none")}</div>
      ) : (
        <ul className="ri-grid">
          {shown.map((z) => {
            const KindIcon = KIND_ICON[z.placed.zone.kind];
            const pct = z.ratio != null ? fmtNumber(Math.round(z.ratio * 100), lang, 0) : null;
            return (
              <li key={z.placed.zone.id}>
                <button
                  type="button"
                  className={`ri-room lvl-${z.isSource ? "danger" : z.level} ${z.isSource ? "src" : ""} ${z.placed.zone.id === selectedId ? "sel" : ""}`}
                  aria-pressed={z.placed.zone.id === selectedId}
                  onClick={() => onSelect(z.placed.zone.id)}
                >
                  <span className={`lvl ${z.isSource ? "danger" : z.level}`} aria-hidden="true" />
                  <span className="ri-main">
                    <span className="ri-name">
                      {KindIcon && <KindIcon />}
                      <span className="ri-name-text">{name(z)}</span>
                      {z.isSource && <span className="ri-src">{t("index.source")}</span>}
                    </span>
                    <span className="ri-unit muted">{unit(z)}</span>
                  </span>
                  <span className="ri-side">
                    <span className="ri-status">
                      {zoneStatusText(z, t)}
                      {pct && z.level !== "unknown" ? ` · ${pct}%` : ""}
                    </span>
                    {z.occupancy > 0 && (
                      <span className="ri-people muted">
                        <PersonIcon /> {fmtNumber(Math.round(z.occupancy), lang, 0)}
                      </span>
                    )}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
