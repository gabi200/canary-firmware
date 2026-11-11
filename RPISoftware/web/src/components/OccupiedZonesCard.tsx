/**
 * Last-known occupied rooms of the open incident, grouped by apartment: one row per apartment with a
 * small chip per occupied room (kind icon, short name, people) and the apartment's total. Occupancy
 * is not a hazard state, so the chips stay neutral; a room with more people stands out by its
 * number (heavier weight), not by colour. Every chip carries the full "room · apartment: N people".
 */
import { pluralCategory, useT } from "../i18n";
import type { ZoneOccupancy } from "../api/types";
import { useZones } from "../api/hooks";
import { fmtNumber } from "../lib/format";
import { buildZoneNames, prettyId, zoneLabel } from "../lib/labels";
import { useScope } from "../lib/scope";
import { Card } from "./Card";
import { PersonIcon } from "./Icons";
import { KIND_ICON } from "./ScopeBar";

const OTHER = "_other";

export function OccupiedZonesCard({ occupied }: { occupied: ZoneOccupancy[] }) {
  const { t, lang } = useT();
  const zones = useZones();
  const { units } = useScope();
  const names = buildZoneNames(zones.data);
  const zoneOf = new Map((zones.data ?? []).map((z) => [z.id, z]));
  const num = (v: number) => fmtNumber(v, lang, v % 1 ? 1 : 0);

  const byUnit = new Map<string, { id: string; label: string; rooms: { id: string; short: string; full: string; kind: string; n: number }[] }>();
  for (const o of occupied) {
    const z = zoneOf.get(o.zone_id);
    const unitId = z?.unit_id ?? OTHER;
    const unitLabel = z ? (units.find((u) => u.id === unitId)?.label ?? z.unit_label ?? prettyId(unitId)) : t("dispatch.otherRooms");
    const row = byUnit.get(unitId) ?? { id: unitId, label: unitLabel, rooms: [] };
    row.rooms.push({
      id: o.zone_id,
      short: z?.label || prettyId(o.zone_id),
      full: zoneLabel(names, o.zone_id),
      kind: z?.kind ?? "",
      n: o.persons_est,
    });
    byUnit.set(unitId, row);
  }
  const rank = new Map(units.map((u, i) => [u.id, i]));
  const rows = [...byUnit.values()].sort((a, b) => (rank.get(a.id) ?? 1e6) - (rank.get(b.id) ?? 1e6));

  return (
    <Card title={t("dispatch.occupiedZones")}>
      {rows.length === 0 ? (
        <div className="muted small">{t("dispatch.noOccupancy")}</div>
      ) : (
        <ul className="oz">
          {rows.map((u) => {
            const total = u.rooms.reduce((s, r) => s + r.n, 0);
            return (
              <li key={u.id} className="oz-row">
                <span className="oz-unit">{u.label}</span>
                <ul className="oz-chips">
                  {u.rooms.map((r) => {
                    const Kind = KIND_ICON[r.kind] as (typeof KIND_ICON)[string] | undefined;
                    const label = t(`dispatch.zoneChip.${pluralCategory(lang, r.n)}`, { room: r.short, unit: u.label, n: num(r.n) });
                    return (
                      <li key={r.id} className={`oz-chip${r.n > 1 ? " many" : ""}`} title={label} aria-label={label} role="img">
                        {Kind && <Kind />}
                        <span className="oz-room">{r.short}</span>
                        <b className="oz-n">{num(r.n)}</b>
                      </li>
                    );
                  })}
                </ul>
                <span className="oz-total muted small" title={t("dispatch.people", { n: num(total) })}>
                  <PersonIcon /> <b>{num(total)}</b>
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}
