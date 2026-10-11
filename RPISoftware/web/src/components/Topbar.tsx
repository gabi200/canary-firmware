import { NavLink } from "react-router-dom";

import { useAuth } from "../auth/AuthContext";
import { useT } from "../i18n";
import { tokenLabel } from "../lib/labels";
import { LangToggle } from "./LangToggle";

export function Topbar({ connected }: { connected: boolean }) {
  const { session, logout } = useAuth();
  const { t } = useT();
  return (
    <div className="topbar">
      <div className="brand">
        Canary<span className="dot">.</span>
      </div>
      <nav className="nav">
        {/* a technician installs rooms and sensors: no incident consoles */}
        {session?.role !== "technician" && (
          <>
            <NavLink to="/manager" className={({ isActive }) => (isActive ? "active" : "")}>
              {t("nav.manager")}
            </NavLink>
            <NavLink to="/dispatch" className={({ isActive }) => (isActive ? "active" : "")}>
              {t("nav.dispatch")}
            </NavLink>
          </>
        )}
        <NavLink to="/sensors" className={({ isActive }) => (isActive ? "active" : "")}>
          {t("nav.sensors")}
        </NavLink>
        {(session?.role === "system_admin" || session?.role === "hoa_manager" || session?.role === "technician") && (
          <NavLink to="/admin" className={({ isActive }) => (isActive ? "active" : "")}>
            {t("nav.admin")}
          </NavLink>
        )}
      </nav>
      <div className="spacer" />
      <span className={`live ${connected ? "" : "off"}`}>
        <span className="led" />
        {connected ? t("topbar.live") : t("topbar.reconnecting")}
      </span>
      <span className="meta">
        {session?.buildingId} · {session ? tokenLabel(t, "role", session.role) : ""}
      </span>
      <LangToggle />
      <button className="btn" onClick={logout}>
        {t("topbar.signOut")}
      </button>
    </div>
  );
}
