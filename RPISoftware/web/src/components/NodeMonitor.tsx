import { useEffect, useMemo, useRef, useState, type RefObject } from "react";

import { useNodeHistory } from "../api/hooks";
import type { NodeOut } from "../api/types";
import { useT, type MsgKey } from "../i18n";
import { HISTORY_FIELDS, rebootTimes, toRows } from "../lib/metrics";
import { MetricTiles } from "./MetricTiles";
import { NodeHistoryCharts } from "./NodeHistoryCharts";

/** Window, button label, caption and polling interval (longer windows: coarser slots). */
const RANGES: { minutes: number; label: MsgKey; caption: MsgKey; refetchMs: number }[] = [
  { minutes: 60, label: "range.1h", caption: "range.lastHour", refetchMs: 30_000 },
  { minutes: 360, label: "range.6h", caption: "range.last6h", refetchMs: 60_000 },
  { minutes: 1440, label: "range.24h", caption: "range.last24h", refetchMs: 120_000 },
  { minutes: 10080, label: "range.7d", caption: "range.last7d", refetchMs: 300_000 },
];

/** Heartbeats (docs/HARDWARE.md §1): a window holding more than 360 of them is aggregated. */
const HEARTBEAT_MS = { air: 15_000, water: 60_000 };

/** True while the element is on (or near) the screen; polling pauses otherwise. */
function useOnScreen(ref: RefObject<HTMLElement>): boolean {
  const [visible, setVisible] = useState(true);
  useEffect(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === "undefined") return;
    const io = new IntersectionObserver(([entry]) => setVisible(entry.isIntersecting), {
      rootMargin: "300px",
    });
    io.observe(el);
    return () => io.disconnect();
  }, [ref]);
  return visible;
}

/** A node's live monitoring block: range selector, HA-style tiles, detail charts. */
export function NodeMonitor({ node, showPresence = true }: { node: NodeOut; showPresence?: boolean }) {
  const { t } = useT();
  const [minutes, setMinutes] = useState(60);
  const box = useRef<HTMLDivElement>(null);
  const onScreen = useOnScreen(box);
  const range = RANGES.find((r) => r.minutes === minutes) ?? RANGES[0];
  // dispatchers may not read presence history (the backend answers 403): never ask for it
  const allFields = HISTORY_FIELDS[node.kind] ?? HISTORY_FIELDS.air;
  const fields = useMemo(
    () => (showPresence ? allFields : allFields.filter((f) => !f.startsWith("presence."))),
    [allFields, showPresence],
  );
  const history = useNodeHistory(node.id, minutes, fields, onScreen ? range.refetchMs : false);

  const data = history.data;
  // the window actually shown (the previous range stays up while a new one loads)
  const shownMinutes = data?.minutes ?? minutes;
  const to = history.dataUpdatedAt || Date.now();
  const from = to - shownMinutes * 60_000;
  const rows = useMemo(() => (data ? toRows(data.points ?? [], fields, node.kind) : []), [data, fields, node.kind]);
  const reboots = useMemo(() => rebootTimes(data?.points ?? []), [data]);
  const inWindow = reboots.filter((r) => r >= from).length;
  const aggregated = (shownMinutes * 60_000) / 360 > (HEARTBEAT_MS[node.kind] ?? 15_000);

  return (
    <div className="node-monitor" ref={box}>
      <div className="charts-head">
        <span className="panel-label">{t("monitor.title")}</span>
        <div className="seg" role="group" aria-label={t("history.range")}>
          {RANGES.map((r) => (
            <button
              key={r.minutes}
              type="button"
              className={r.minutes === minutes ? "active" : ""}
              aria-pressed={r.minutes === minutes}
              onClick={() => setMinutes(r.minutes)}
            >
              {t(r.label)}
            </button>
          ))}
        </div>
        <span className="muted small">{t(range.caption)}</span>
        {inWindow > 0 && <span className="reboot-count small">{t("monitor.reboots", { n: inWindow })}</span>}
        <span className="spacer" />
        {history.isFetching && <span className="muted small">{t("history.updating")}</span>}
      </div>

      <MetricTiles node={node} rows={rows} from={from} to={to} />

      {history.isError && !data ? (
        <div className="err">{t("history.unavailable", { msg: (history.error as Error).message })}</div>
      ) : !data ? (
        <div className="muted small">{t("history.loading")}</div>
      ) : (
        <>
          <NodeHistoryCharts
            node={node}
            win={{ rows, from, to, minutes: shownMinutes, reboots }}
            showPresence={showPresence}
          />
          <div className="chart-foot muted small">
            {t("monitor.gapNote")}
            {aggregated && <> {t("monitor.bucketNote")}</>}
          </div>
        </>
      )}
    </div>
  );
}
