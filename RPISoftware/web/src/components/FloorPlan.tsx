import type { Device, Incident, Reading, Zone } from "../api/types";

interface Props {
  zones: Zone[];
  devices: Device[];
  latest: Map<string, Reading>;
  incident?: Incident | null;
  occupancyByZone?: Record<string, number>;
}

const CELL_W = 200;
const CELL_H = 130;
const GAP = 18;

function deviceColor(reading?: Reading): string {
  if (!reading) return "#8b98a8";
  switch (reading.edge_state) {
    case "alarm":
      return "#f85149";
    case "warn":
      return "#d29922";
    default:
      return "#2ea043";
  }
}

type ZoneKind = "source" | "affected" | "warn" | "idle";

export function FloorPlan({ zones, devices, latest, incident, occupancyByZone }: Props) {
  const n = Math.max(zones.length, 1);
  const cols = Math.max(1, Math.ceil(Math.sqrt(n)));
  const rows = Math.ceil(n / cols);
  const width = GAP + cols * (CELL_W + GAP);
  const height = GAP + rows * (CELL_H + GAP);

  const byZone = new Map<string, Device[]>();
  for (const d of devices) {
    const arr = byZone.get(d.zone_id) ?? [];
    arr.push(d);
    byZone.set(d.zone_id, arr);
  }

  const affected = new Set(incident?.affected_zone_ids ?? []);
  // Prefer the AI-triangulated source; fall back to the first-detection zone.
  const sourceZoneId = incident ? incident.est_source_zone_id ?? incident.primary_zone_id : null;
  const sourceConf = incident?.triangulation_confidence ?? null;

  function kindOf(zone: Zone): ZoneKind {
    if (incident) {
      if (sourceZoneId === zone.id) return "source";
      if (affected.has(zone.id)) return "affected";
    }
    const devs = byZone.get(zone.id) ?? [];
    if (devs.some((d) => latest.get(d.id)?.edge_state === "alarm")) return "affected";
    if (devs.some((d) => latest.get(d.id)?.edge_state === "warn")) return "warn";
    return "idle";
  }

  const fill: Record<ZoneKind, string> = {
    source: "rgba(182,35,36,0.55)",
    affected: "rgba(248,81,73,0.28)",
    warn: "rgba(210,153,34,0.20)",
    idle: "#222c38",
  };

  return (
    <div>
      <svg className="floorplan" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="xMidYMid meet">
        {zones.map((zone, i) => {
          const col = i % cols;
          const row = Math.floor(i / cols);
          const x = GAP + col * (CELL_W + GAP);
          const y = GAP + row * (CELL_H + GAP);
          const kind = kindOf(zone);
          const devs = byZone.get(zone.id) ?? [];
          const occ = occupancyByZone?.[zone.id] ?? 0;
          const cx = x + CELL_W / 2;
          const cy = y + CELL_H / 2;
          return (
            <g key={zone.id}>
              <rect
                x={x}
                y={y}
                width={CELL_W}
                height={CELL_H}
                rx={12}
                fill={fill[kind]}
                stroke={kind === "source" ? "#b62324" : "#2c3846"}
                strokeWidth={kind === "source" ? 3 : 1.5}
              />
              <text x={x + 14} y={y + 26} fill="#e6edf3" fontSize={15} fontWeight={700}>
                {zone.label || zone.id}
              </text>
              <text x={x + 14} y={y + 44} fill="#8b98a8" fontSize={11}>
                {zone.kind}
              </text>

              {/* occupancy badge */}
              {occ > 0 && (
                <text x={x + CELL_W - 14} y={y + 26} fill="#e6edf3" fontSize={13} textAnchor="end">
                  ● {occ}
                </text>
              )}

              {/* sensor dots */}
              {devs.map((d, di) => {
                const dotX = x + 18 + di * 22;
                const dotY = y + CELL_H - 22;
                return (
                  <circle key={d.id} cx={dotX} cy={dotY} r={7} fill={deviceColor(latest.get(d.id))}>
                    <title>
                      {d.sensor_type} · {latest.get(d.id)?.value ?? "—"} {latest.get(d.id)?.units ?? ""}
                    </title>
                  </circle>
                );
              })}

              {/* triangulated-source marker (MVP: primary zone of the active incident) */}
              {kind === "source" && (
                <g>
                  <circle cx={cx} cy={cy} r={16} fill="none" stroke="#ffffff" strokeWidth={2}>
                    <animate attributeName="r" values="14;28;14" dur="1.6s" repeatCount="indefinite" />
                    <animate attributeName="opacity" values="1;0.1;1" dur="1.6s" repeatCount="indefinite" />
                  </circle>
                  <circle cx={cx} cy={cy} r={7} fill="#ffffff" />
                  <text x={cx} y={cy + 34} fill="#ffffff" fontSize={11} fontWeight={700} textAnchor="middle">
                    SOURCE{sourceConf != null ? ` · ${Math.round(sourceConf * 100)}%` : ""}
                  </text>
                </g>
              )}
            </g>
          );
        })}
      </svg>

      <div className="legend">
        <span><span className="sw" style={{ background: "#2ea043" }} /> normal</span>
        <span><span className="sw" style={{ background: "#d29922" }} /> warning</span>
        <span><span className="sw" style={{ background: "#f85149" }} /> alarm</span>
        <span><span className="sw" style={{ background: "#b62324" }} /> hazard source</span>
        <span><span className="sw" style={{ background: "#8b98a8" }} /> no data</span>
      </div>
    </div>
  );
}
