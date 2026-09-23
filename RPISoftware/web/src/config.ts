const rawBase = import.meta.env.VITE_API_BASE ?? "http://localhost:8000";

export const config = {
  apiBase: rawBase.replace(/\/$/, ""),
  get wsBase() {
    return this.apiBase.replace(/^http/, "ws");
  },
  defaultBuildingId: "bld_007",
  /** Incident states that put the building into an alarming posture. */
  alarmingStates: new Set(["alarm", "escalation", "evacuation"]),
};
