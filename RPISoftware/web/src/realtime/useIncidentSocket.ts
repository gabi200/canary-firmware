import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";

import type { WsEvent } from "../api/types";
import { config } from "../config";

/**
 * Subscribes to the per-building incident WebSocket and invalidates the relevant
 * React Query caches on each event so the dashboard updates live. Auto-reconnects
 * with capped backoff. Returns connection status + the latest event.
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
        setConnected(true);
        backoff = 1000;
      };
      ws.onmessage = (ev) => {
        try {
          const data = JSON.parse(ev.data as string) as WsEvent;
          setLastEvent(data);
          qc.invalidateQueries({ queryKey: ["incidents"] });
          qc.invalidateQueries({ queryKey: ["accounting"] });
          qc.invalidateQueries({ queryKey: ["occupancy"] });
          qc.invalidateQueries({ queryKey: ["roster"] });
          if (data.type === "incident") {
            qc.invalidateQueries({ queryKey: ["events"] });
            qc.invalidateQueries({ queryKey: ["triangulation"] });
          }
        } catch {
          /* ignore malformed frame */
        }
      };
      ws.onclose = () => {
        setConnected(false);
        if (stopped) return;
        timer = window.setTimeout(connect, backoff);
        backoff = Math.min(backoff * 2, 15000);
      };
      ws.onerror = () => closeSocket(ws);
    };

    connect();
    return () => {
      stopped = true;
      if (timer) window.clearTimeout(timer);
      closeSocket(ws);
    };
  }, [buildingId, token, qc]);

  return { connected, lastEvent };
}
