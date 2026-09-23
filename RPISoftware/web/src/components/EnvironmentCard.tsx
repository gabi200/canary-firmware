import { Link } from "react-router-dom";

import { useSummary } from "../api/hooks";
import { LEVEL_LABEL } from "../lib/nodes";
import { Card } from "./Card";
import { StatusPill } from "./StatusPill";

/** Compact building environment status for the manager view; details live on /sensors. */
export function EnvironmentCard() {
  const summary = useSummary();
  const s = summary.data;

  return (
    <Card title="Environment">
      {!s ? (
        <div className="muted small">
          {summary.isError ? "Sensor analysis unavailable." : "Loading…"}
        </div>
      ) : (
        <>
          <div className="row">
            <StatusPill state={s.status} label={LEVEL_LABEL[s.status] ?? s.status} />
            <div className="grow">
              <div>{s.headline}</div>
              <div className="muted small">
                {s.nodes_online}/{s.nodes_total} sensor nodes online
              </div>
            </div>
            <Link to="/sensors" className="small">
              Sensors →
            </Link>
          </div>
          {(s.zones ?? []).flatMap((z) =>
            z.nodes.map((n) => (
              <div className="row" key={n.node_id}>
                <span className={`lvl ${n.status}`} title={LEVEL_LABEL[n.status]} />
                <div className="small env-node">
                  {n.name} <span className="muted">· {z.zone_label}</span>
                </div>
                <div className={`grow small env-node-headline t-${n.status}`}>{n.headline}</div>
              </div>
            )),
          )}
        </>
      )}
    </Card>
  );
}
