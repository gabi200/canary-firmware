import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";

import type { WsEvent } from "../api/types";
import { config } from "../config";
import { applyCommandEvent } from "../lib/commands";

/** Runs `fn` at most once per `ms`; a call inside the window schedules one trailing run
 *  so the latest event is never dropped. */
function throttle(fn: () => void, ms: number) {
  let last = 0;
  let timer: number | undefined;
  const run = () => {
    timer = undefined;
    last = Date.now();
    fn();
  };
  const call = () => {
    const wait = last + ms - Date.now();
    if (wait <= 0) run();
    else if (timer === undefined) timer = window.setTimeout(run, wait);
  };
  call.cancel = () => window.clearTimeout(timer);
  return call;
}

/**
 * Subscribes to the per-building incident WebSocket and invalidates the relevant
 * React Query caches on each event so the dashboard updates live. Auto-reconnects
 * with capped backoff. Returns connection status + the latest event.
 *
 * `node` events (a hardware status/availability message was processed) refresh only the
 * sensor queries: summary + nodes (bursts coalesced) and the reporting nodes' raw history
 * (at most every 10 s). `command_result` events (a device answered a hardware-test command)
 * settle the live command store (lib/commands.ts).
 */
export function useIncidentSocket(buildingId: string, token: string | null) {
  const qc = useQueryClient();
  const [connected, setConnected] = useState(false);
  const [lastEvent, setLastEvent] = useState<WsEvent | null>(null);

  useEffect(() => {
    if (!token) return;
    let stopped = false;
    let ws: WebSocket | null = null;
    let timer: number | undefined;
    let backoff = 1000;
    const refreshNodes = throttle(() => {
      qc.invalidateQueries({ queryKey: ["summary"] });
      qc.invalidateQueries({ queryKey: ["nodes"] });
    }, 2_000);
    // only the nodes that reported since the last history refresh, and only short windows
    // (≤ 6 h, aggregated slots ≤ 1 min): longer ones poll on their own slower interval
    const historyDue = new Set<string>();
    const refreshHistory = throttle(() => {
      for (const id of historyDue) {
        qc.invalidateQueries({
          queryKey: ["history", id],
          predicate: (q) => typeof q.queryKey[2] !== "number" || q.queryKey[2] <= 360,
        });
      }
      historyDue.clear();
    }, 10_000);

    // Closing a socket that is still CONNECTING triggers the noisy browser warning
    // "WebSocket is closed before the connection is established" (common under React
    // StrictMode's mount/cleanup/mount). Defer the close until the socket opens.
    const closeSocket = (sock: WebSocket | null) => {
      if (!sock) return;
      if (sock.readyState === WebSocket.CONNECTING) {
        sock.addEventListener("open", () => sock.close(), { once: true });
      } else if (sock.readyState === WebSocket.OPEN) {
        sock.close();
      }
    };

    const connect = () => {
      const url = `${config.wsBase}/api/v1/ws/incidents?building_id=${buildingId}&token=${token}`;
      ws = new WebSocket(url);
      ws.onopen = () => {
        if (stopped) return; // socket of a cleaned-up effect (StrictMode / token change)
        setConnected(true);
        backoff = 1000;
      };
      ws.onmessage = (ev) => {
        if (stopped) return;
        try {
          const data = JSON.parse(ev.data as string) as WsEvent;
          if (data.type === "node") {
            setLastEvent(data);
            refreshNodes();
            if (data.node_id) {
              historyDue.add(data.node_id);
              refreshHistory();
            }
            return;
          }
          if (data.type === "command_result") {
            // a device answered a command (hardware test): settle its live status chip
            applyCommandEvent(data, qc);
            return;
          }
          if (data.type === "care_checkin") {
            // a priority person checked in: refresh who is still waiting (no health data here)
            setLastEvent(data);
            qc.invalidateQueries({ queryKey: ["roster"] });
            qc.invalidateQueries({ queryKey: ["accounting"] });
            return;
          }
          if (data.type === "location") {
            // a resident answered "Where are you now?": shown in the roster
            qc.invalidateQueries({ queryKey: ["roster"] });
            return;
          }
          if (data.type !== "incident" && data.type !== "checkin") return; // unknown event type
          setLastEvent(data);
          qc.invalidateQueries({ queryKey: ["incidents"] });
          qc.invalidateQueries({ queryKey: ["accounting"] });
          qc.invalidateQueries({ queryKey: ["occupancy"] });
          qc.invalidateQueries({ queryKey: ["roster"] });
          if (data.type === "incident") {
            qc.invalidateQueries({ queryKey: ["events"] });
            qc.invalidateQueries({ queryKey: ["triangulation"] });
            qc.invalidateQueries({ queryKey: ["triangulationHistory"] });
            qc.invalidateQueries({ queryKey: ["escalations"] });
            refreshNodes(); // building status/headline are derived from open incidents
          }
        } catch {
          /* ignore malformed frame */
        }
      };
      ws.onclose = () => {
        // a stale socket closing late must not mark the current one as disconnected
        if (stopped) return;
        setConnected(false);
        timer = window.setTimeout(connect, backoff);
        backoff = Math.min(backoff * 2, 15000);
      };
      ws.onerror = () => closeSocket(ws);
    };

    connect();
    // Three-Pi hub: the socket runs through the floating hub address. If the Pi behind it dies, an
    // idle socket never notices; a small frame every 25 s meets a reset from the Pi that took the
    // address over, which closes it and reconnects. The server ignores client frames.
    const ping = window.setInterval(() => {
      if (ws?.readyState === WebSocket.OPEN) ws.send("ping");
    }, 25_000);
    return () => {
      stopped = true;
      setConnected(false);
      window.clearInterval(ping);
      if (timer) window.clearTimeout(timer);
      refreshNodes.cancel();
      refreshHistory.cancel();
      closeSocket(ws);
    };
  }, [buildingId, token, qc]);

  return { connected, lastEvent };
}
