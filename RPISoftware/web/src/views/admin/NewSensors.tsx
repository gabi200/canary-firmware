/**
 * New sensors: nodes that connected to the hub on their own and nobody has placed in a room yet
 * (`is_new`). The technician beeps an air sensor to find it, then picks its room; the hub uses
 * that room for detection right away. Shown on top of the Devices tab and, as "put it here",
 * under the selected room of the Rooms tab.
 */
import { useQueryClient } from "@tanstack/react-query";

import { useMoveNode } from "../../api/adminHooks";
import { useNodes, useZones } from "../../api/hooks";
import type { NodeOut, Zone } from "../../api/types";
import { useAuth } from "../../auth/AuthContext";
import { BellIcon, DropletIcon, InfoIcon, WindIcon } from "../../components/Icons";
import { useT } from "../../i18n";
import { fmtNumber } from "../../lib/format";
import { isPending, sendNodeCommand, useLiveCommand } from "../../lib/commands";
import { fmtAgo } from "../../lib/time";
import { natural } from "./roomModel";

export function useNewSensors(): NodeOut[] {
  const nodes = useNodes();
  return (nodes.data ?? []).filter((n) => n.is_new).sort((a, b) => natural(a.name || a.id, b.name || b.id));
}

/** Air sensors only: water sensors have no test beep (find them by their name). */
function BeepButton({ node }: { node: NodeOut }) {
  const { t } = useT();
  const { token } = useAuth();
  const qc = useQueryClient();
  const live = useLiveCommand(node.id);
  if (node.kind !== "air") return null;
  const busy = isPending(live);
  return (
    <button
      type="button"
      className="btn small-btn"
      disabled={!node.online || busy || !token}
      title={t("newsens.beepHint")}
      onClick={() => token && sendNodeCommand({ token, nodeId: node.id, command: "TEST", qc })}
    >
      <BellIcon /> {busy ? t("newsens.beeping") : t("newsens.beep")}
    </button>
  );
}

function SensorHead({ node }: { node: NodeOut }) {
  const { t, lang } = useT();
  return (
    <div className="ns-head">
      <span className="ns-kind" aria-hidden="true">
        {node.kind === "water" ? <DropletIcon /> : <WindIcon />}
      </span>
      <div className="ns-name">
        <b>{node.name || node.id}</b>
        <span className="muted small">
          {node.mqtt_base}
          {node.last_seen_ts ? ` · ${fmtAgo(node.last_seen_ts, lang)}` : ""}
        </span>
      </div>
      <span className={`pill ${node.online ? "ok" : "attention"}`}>{t(node.online ? "conn.online" : "conn.offline")}</span>
    </div>
  );
}

/** Rooms grouped "Etaj 3 · Ap. 12", floors and apartments in natural order. */
function roomGroups(zones: Zone[]): [string, Zone[]][] {
  const groups = new Map<string, Zone[]>();
  for (const z of zones) {
    const key = [z.floor_label, z.unit_label].filter(Boolean).join(" · ") || z.unit_id;
    groups.set(key, [...(groups.get(key) ?? []), z]);
  }
  return [...groups]
    .sort(([a], [b]) => natural(a, b))
    .map(([k, zs]) => [k, zs.sort((a, b) => natural(a.label, b.label))]);
}

/** Devices tab: every new sensor with a beep and a room picker. Nothing new: a short how-to. */
export function NewSensorsPanel() {
  const { t, lang } = useT();
  const fresh = useNewSensors();
  const zones = useZones();
  const move = useMoveNode();
  if (fresh.length === 0) {
    return (
      <div className="ns-empty muted small">
        <InfoIcon /> {t("newsens.empty")}
      </div>
    );
  }
  const groups = roomGroups(zones.data ?? []);
  return (
    <section className="card ns-panel" aria-labelledby="ns-title">
      <h3 id="ns-title" className="ns-title">
        <span className="ns-dot" aria-hidden="true" />
        {t("newsens.title", { n: fmtNumber(fresh.length, lang, 0) })}
      </h3>
      <p className="muted small">{t("newsens.hint")}</p>
      <ul className="ns-list">
        {fresh.map((n) => (
          <li key={n.id} className="ns-item">
            <SensorHead node={n} />
            <div className="ns-actions">
              <BeepButton node={n} />
              <select
                className="input"
                aria-label={t("newsens.chooseRoomFor", { name: n.name || n.id })}
                value=""
                disabled={move.isPending}
                onChange={(e) => e.target.value && move.mutate({ nodeId: n.id, patch: { zone_id: e.target.value } })}
              >
                <option value="">{t("newsens.chooseRoom")}</option>
                {groups.map(([group, zs]) => (
                  <optgroup key={group} label={group}>
                    {zs.map((z) => (
                      <option key={z.id} value={z.id}>
                        {z.label}
                      </option>
                    ))}
                  </optgroup>
                ))}
              </select>
            </div>
          </li>
        ))}
      </ul>
      {move.isError && <div className="err">{t("admin.saveFailed", { msg: (move.error as Error).message })}</div>}
    </section>
  );
}

/** Rooms tab, under the selected room: new sensors with "put in this room". */
export function PlaceHere({ zoneId }: { zoneId: string }) {
  const { t } = useT();
  const fresh = useNewSensors();
  const move = useMoveNode();
  if (fresh.length === 0) return null;
  return (
    <div className="ns-here">
      <div className="panel-label">{t("newsens.waiting")}</div>
      <ul className="ns-list">
        {fresh.map((n) => (
          <li key={n.id} className="ns-item">
            <SensorHead node={n} />
            <div className="ns-actions">
              <BeepButton node={n} />
              <button
                type="button"
                className="btn small-btn primary"
                disabled={move.isPending}
                onClick={() => move.mutate({ nodeId: n.id, patch: { zone_id: zoneId } })}
              >
                {t("newsens.putHere")}
              </button>
            </div>
          </li>
        ))}
      </ul>
      {move.isError && <div className="err">{t("admin.saveFailed", { msg: (move.error as Error).message })}</div>}
    </div>
  );
}
