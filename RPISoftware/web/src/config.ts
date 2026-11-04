/**
 * VITE_API_BASE (build time):
 *   unset  -> http://localhost:8000 (`npm run dev` next to a local backend)
 *   ""     -> same origin: REST on relative /api/... URLs, WebSocket on ws(s)://<page host>
 *             (the Pi's nginx serves this app and proxies /api, WebSocket included)
 *   a URL  -> that backend, e.g. http://192.168.1.20:8000
 */
const rawBase = import.meta.env.VITE_API_BASE ?? "http://localhost:8000";

export const config = {
  apiBase: rawBase.trim().replace(/\/+$/, ""),
  get wsBase() {
    if (!this.apiBase) {
      return `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}`;
    }
    return this.apiBase.replace(/^http/, "ws");
  },
  defaultBuildingId: "bld_live",
  /** Incident states that put the building into an alarming posture. */
  alarmingStates: new Set(["alarm", "escalation", "evacuation"]),
};
