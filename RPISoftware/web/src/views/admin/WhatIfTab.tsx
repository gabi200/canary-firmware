/**
 * Evacuation what-if: mark corridors or stairs of a simulated floor graph unavailable and see the
 * recomputed paths, rooms with no exit, and the busiest passages. Labelled throughout as a scenario,
 * not a safety prediction; it never reads or changes the building's evacuation routes.
 */
import { useState } from "react";

import { useEvacuationScenario } from "../../api/hooks";
import { Card } from "../../components/Card";
import { useT } from "../../i18n";
import { fmtNumber } from "../../lib/format";

export function WhatIfTab() {
  const { t, lang } = useT();
  const [blocked, setBlocked] = useState<string[]>([]);
  const scenario = useEvacuationScenario(blocked);
  const d = scenario.data;
  const name = (id: string) => d?.nodes.find((n) => n.id === id)?.label ?? id;
  const edgeName = (id: string) => {
    const e = d?.edges.find((x) => x.id === id);
    return e ? `${name(e.a)} ↔ ${name(e.b)}` : id;
  };
  const toggle = (id: string) => setBlocked((b) => (b.includes(id) ? b.filter((x) => x !== id) : [...b, id]));

  return (
    <Card title={t("whatif.title")}>
      <div className="scenario-banner">
        <strong>{d?.label ?? "scenario — not a safety prediction"}</strong>
        <div className="small">{t("whatif.banner")}</div>
        {d && <div className="muted small">{d.graph_label}</div>}
      </div>
      {scenario.isError && <div className="muted small">{t("whatif.unavailable")}</div>}
      {d && (
        <div className="grid cols-even">
          <div>
            <div className="panel-label">{t("whatif.block")}</div>
            {d.nodes
              .filter((n) => n.kind === "corridor" || n.kind === "stair")
              .map((n) => (
                <label key={n.id} className="row" style={{ marginBottom: 4, cursor: "pointer" }}>
                  <input type="checkbox" checked={blocked.includes(n.id)} onChange={() => toggle(n.id)} />
                  <span className="grow">{n.label}</span>
                </label>
              ))}
            <div className="panel-label" style={{ marginTop: 12 }}>{t("whatif.paths")}</div>
            {d.rooms.map((r) => (
              <div key={r.room_id} style={{ marginBottom: 6 }}>
                <div>
                  {name(r.room_id)} <span className="muted small">({fmtNumber(r.people, lang, 0)})</span>
                </div>
                <div className="small">
                  {r.exit_id ? (
                    <>
                      <span className="muted">{r.path.slice(1, -1).map(name).join(" → ")}</span>{" "}
                      {t("whatif.toExit", { exit: name(r.exit_id), m: fmtNumber(r.length_m ?? 0, lang, 0) })}
                    </>
                  ) : (
                    <span className="pill danger">{t("whatif.stranded")}</span>
                  )}
                </div>
              </div>
            ))}
            {d.stranded_people > 0 && (
              <div className="pill danger" style={{ marginTop: 6 }}>
                {t("whatif.strandedTotal", { n: d.stranded_people })}
              </div>
            )}
          </div>
          <div>
            <div className="panel-label">{t("whatif.bottlenecks")}</div>
            {d.loads.slice(0, 6).map((l, i) => (
              <div key={l.edge_id} className="row" style={{ marginBottom: 6 }}>
                <div className="grow">
                  {edgeName(l.edge_id)}
                  <div className="muted small">
                    {t("whatif.load", {
                      people: l.people,
                      cap: fmtNumber(l.capacity_ppm, lang, 0),
                      min: fmtNumber(l.minutes_to_clear, lang, 2),
                    })}
                  </div>
                </div>
                {i === 0 && <span className="pill attention">#1</span>}
              </div>
            ))}
            <div className="muted small" style={{ marginTop: 8 }}>{t("whatif.loadNote")}</div>
          </div>
        </div>
      )}
    </Card>
  );
}
