/**
 * Devices: every sensor of the chosen apartment / room (scope bar) as a big card (name, room,
 * kind, online / offline, last seen, firmware, Wi-Fi bars, last test) with the hardware test
 * buttons. Filters: all / offline / never tested / failed; "Test all" runs TEST on each online
 * air sensor of the scope in turn.
 */
import { useMemo, useState } from "react";

import { useDeleteNode } from "../../api/adminHooks";
import { ApiError } from "../../api/client";
import { useNodes, useZones } from "../../api/hooks";
import type { NodeOut } from "../../api/types";
import { ConfirmDialog } from "../../components/ConfirmDialog";
import { BellIcon, DropletIcon, PlayIcon, TrashIcon, WindIcon } from "../../components/Icons";
import { NodeCommands, canCommand } from "../../components/NodeCommands";
import { WifiBars } from "../../components/WifiBars";
import { useAuth } from "../../auth/AuthContext";
import { pluralCategory, useT } from "../../i18n";
import { lastCommandOutcome, useLiveCommands, type LiveCommand } from "../../lib/commands";
import { fmtNumber } from "../../lib/format";
import { buildZoneNames, deviceToken, kindLabel } from "../../lib/labels";
import { connectivity, pick, pickNum } from "../../lib/nodes";
import { useScope } from "../../lib/scope";
import { fmtAgo, fmtDateTime } from "../../lib/time";
import { AdminUnavailable } from "./AdminUnavailable";
import { NewSensorsPanel } from "./NewSensors";
import { natural } from "./roomModel";
import { TestAllPanel } from "./TestAllPanel";

type Filter = "all" | "offline" | "untested" | "failed";
type Outcome = "none" | "pending" | "ok" | "failed";

/** Newest known result of a node: this browser's live command, else the hub's last_command. */
function outcomeOf(node: NodeOut, live: LiveCommand | undefined): Outcome {
  const { outcome } = lastCommandOutcome(node, live);
  return outcome === "rejected" || outcome === "timeout" ? "failed" : outcome;
}

/** Offline sensors only: remove it from the building (it re-registers itself if it reconnects). */
function DeleteSensor({ node }: { node: NodeOut }) {
  const { t } = useT();
  const del = useDeleteNode();
  const [confirm, setConfirm] = useState(false);
  return (
    <div className="dev-delete">
      <button type="button" className="btn danger-outline small-btn" disabled={del.isPending} onClick={() => setConfirm(true)}>
        <TrashIcon /> {t("devs.delete")}
      </button>
      {del.isError && (
        <div className="err">
          {del.error instanceof ApiError && del.error.status === 409
            ? t("devs.deleteOnline")
            : t("admin.saveFailed", { msg: (del.error as Error).message })}
        </div>
      )}
      {confirm && (
        <ConfirmDialog
          title={t("devs.confirmDeleteTitle", { name: node.name || node.id })}
          confirmLabel={t("devs.delete")}
          danger
          busy={del.isPending}
          onCancel={() => setConfirm(false)}
          onConfirm={() => del.mutate(node.id, { onSettled: () => setConfirm(false) })}
        >
          <p>{t("devs.confirmDeleteBody")}</p>
        </ConfirmDialog>
      )}
    </div>
  );
}

function DeviceCard({ node, room }: { node: NodeOut; room: string }) {
  const { t, lang } = useT();
  const { session } = useAuth();
  const conn = connectivity(node);
  const doc = node.status;
  const fw = node.firmware ?? pick(doc, "device.firmware");
  const rssi = pickNum(doc, "wifi.rssi");
  const valve = node.kind === "water" ? pick(doc, "valve.applied") : undefined;
  const alarm = pick(doc, "alarm.state");
  const sounding = pick(doc, "alarm.sounding") === true;
  const selfTest = pick(doc, "alarm.self_test") === true;

  return (
    <article className={`dev-card conn-${conn.state}`}>
      <div className="dev-head">
        <span className={`dev-kind ${node.kind}`} aria-hidden="true">
          {node.kind === "water" ? <DropletIcon /> : <WindIcon />}
        </span>
        <div className="dev-title">
          <div className="dev-name">{node.name || node.id}</div>
          <div className="dev-room">{room}</div>
        </div>
        <span className={`dev-conn ${conn.state}`}>
          <span className="dot" aria-hidden="true" />
          {t(`conn.${conn.state}`)}
        </span>
      </div>
      <dl className="dev-facts">
        <div>
          <dt>{t("devs.kind")}</dt>
          <dd>{kindLabel(node.kind, t)}</dd>
        </div>
        <div>
          <dt>{t("devs.lastSeen")}</dt>
          <dd title={node.last_seen_ts ? fmtDateTime(node.last_seen_ts, lang) : undefined}>{fmtAgo(node.last_seen_ts, lang)}</dd>
        </div>
        <div>
          <dt>{t("devs.firmware")}</dt>
          <dd className="mono">{typeof fw === "string" && fw ? fw : "—"}</dd>
        </div>
        <div>
          <dt>{t("devs.wifi")}</dt>
          <dd>
            <WifiBars rssi={rssi} />
          </dd>
        </div>
        {node.kind === "water" && (
          <div>
            <dt>{t("devs.valve")}</dt>
            <dd className={valve === "closed" ? "t-attention" : ""}>
              {valve === "open" || valve === "closed" ? t(valve === "open" ? "valve.open" : "valve.closed") : "—"}
            </dd>
          </div>
        )}
        {typeof alarm === "string" && alarm !== "inactive" && (
          <div>
            <dt>{t("devs.alarm")}</dt>
            <dd className={sounding ? "t-danger" : "t-attention"}>
              {selfTest ? t("devs.selfTestNow") : deviceToken(alarm, t)}
            </dd>
          </div>
        )}
      </dl>
      <NodeCommands node={node} variant="full" />
      <div className="dev-foot">
        <span className="dev-id muted small mono">{node.id}</span>
        {!node.online && canCommand(session?.role) && <DeleteSensor node={node} />}
      </div>
    </article>
  );
}

export function DevicesTab() {
  const { t, lang } = useT();
  const { session } = useAuth();
  const nodes = useNodes();
  const zones = useZones();
  const live = useLiveCommands();
  const sc = useScope();
  const [filter, setFilter] = useState<Filter>("all");
  const [confirmAll, setConfirmAll] = useState(false);
  // the run keeps the scope it was started in, whatever the bar shows later
  const [testRun, setTestRun] = useState<{ targets: NodeOut[]; scope: string } | null>(null);
  const names = buildZoneNames(zones.data);
  const zoneById = useMemo(() => new Map((zones.data ?? []).map((z) => [z.id, z])), [zones.data]);

  const roomOf = (n: NodeOut) => {
    const z = zoneById.get(n.zone_id);
    if (!z) return names.get(n.zone_id) ?? t("devs.unknownRoom");
    return z.unit_label ? `${z.label} · ${z.unit_label}` : z.label;
  };

  // apartment by apartment (the scope bar's order), then room, kind and name
  const order = new Map(sc.rooms.map((r, i) => [r.id, i]));
  const rank = (n: NodeOut) => order.get(n.zone_id) ?? sc.rooms.length;
  const sorted = (nodes.data ?? [])
    .filter((n) => sc.includes(n.zone_id))
    .sort(
      (a, b) =>
        rank(a) - rank(b) || natural(roomOf(a), roomOf(b)) || a.kind.localeCompare(b.kind) || natural(a.name || a.id, b.name || b.id),
    );

  if (nodes.isError && !nodes.data) return <AdminUnavailable error={nodes.error} />;
  if (!nodes.data || !sc.ready) return <div className="muted">{t("common.loading")}</div>;

  const outcome = new Map(sorted.map((n) => [n.id, outcomeOf(n, live.get(n.id))]));
  const counts = {
    all: sorted.length,
    online: sorted.filter((n) => n.online).length,
    offline: sorted.filter((n) => !n.online).length,
    untested: sorted.filter((n) => outcome.get(n.id) === "none").length,
    failed: sorted.filter((n) => outcome.get(n.id) === "failed").length,
  };
  const shown = sorted.filter((n) =>
    filter === "offline"
      ? !n.online
      : filter === "untested"
        ? outcome.get(n.id) === "none"
        : filter === "failed"
          ? outcome.get(n.id) === "failed"
          : true,
  );
  const airOnline = sorted.filter((n) => n.kind === "air" && n.online);
  const num = (v: number) => fmtNumber(v, lang, 0);
  const plural = (base: "rooms.sensorCount" | "devs.untested", v: number) =>
    t(`${base}.${pluralCategory(lang, v)}`, { n: num(v) });

  const FILTERS: { id: Filter; label: string; n: number }[] = [
    { id: "all", label: t("devs.filterAll"), n: counts.all },
    { id: "offline", label: t("devs.filterOffline"), n: counts.offline },
    { id: "untested", label: t("devs.filterUntested"), n: counts.untested },
    { id: "failed", label: t("devs.filterFailed"), n: counts.failed },
  ];

  return (
    <>
      <NewSensorsPanel />
      <div className="devs-head">
        <div className="devs-counter">
          <b>{plural("rooms.sensorCount", counts.all)}</b>
          <span className="t-ok">
            <span className="sep">·</span>
            {t("devs.online", { n: num(counts.online) })}
          </span>
          <span className={counts.offline ? "t-danger" : "muted"}>
            <span className="sep">·</span>
            {t("devs.offline", { n: num(counts.offline) })}
          </span>
          <span className={counts.untested ? "t-attention" : "muted"}>
            <span className="sep">·</span>
            {plural("devs.untested", counts.untested)}
          </span>
        </div>
        <span className="spacer" />
        {canCommand(session?.role) && (
          <button
            type="button"
            className="btn primary big-btn"
            disabled={airOnline.length === 0 || !!testRun}
            title={airOnline.length === 0 ? t("testall.noneOnline") : t("devs.testAllHint")}
            onClick={() => setConfirmAll(true)}
          >
            <PlayIcon /> {t("devs.testAll")} · {sc.title}
          </button>
        )}
      </div>
      <div className="devs-filters">
        <div className="seg big-seg" role="group" aria-label={t("devs.filterAria")}>
          {FILTERS.map((f) => (
            <button key={f.id} type="button" className={filter === f.id ? "active" : ""} aria-pressed={filter === f.id} onClick={() => setFilter(f.id)}>
              {f.label} <span className="seg-n">{num(f.n)}</span>
            </button>
          ))}
        </div>
        <span className="muted small">{t("devs.testAllHint")}</span>
      </div>

      {testRun && (
        <TestAllPanel targets={testRun.targets} scope={testRun.scope} roomOf={roomOf} onClose={() => setTestRun(null)} />
      )}

      {nodes.data.length === 0 ? (
        <div className="card muted">{t("devs.noNodes")}</div>
      ) : sorted.length === 0 ? (
        <div className="card muted">{t("scope.noSensors", { scope: sc.title })}</div>
      ) : shown.length === 0 ? (
        <div className="card muted">{t("devs.none")}</div>
      ) : (
        <div className="dev-grid">
          {shown.map((n) => (
            <DeviceCard key={n.id} node={n} room={roomOf(n)} />
          ))}
        </div>
      )}

      {confirmAll && (
        <ConfirmDialog
          title={sc.unit ? t("testall.confirmTitleScoped", { scope: sc.title }) : t("testall.confirmTitle")}
          confirmLabel={t("testall.start")}
          onCancel={() => setConfirmAll(false)}
          onConfirm={() => {
            setConfirmAll(false);
            setTestRun({ targets: airOnline, scope: sc.title });
          }}
        >
          <p>
            <BellIcon /> {t("testall.confirmBody", { n: num(airOnline.length) })}
          </p>
          <p className="muted small">{t("testall.confirmWater")}</p>
        </ConfirmDialog>
      )}
    </>
  );
}
