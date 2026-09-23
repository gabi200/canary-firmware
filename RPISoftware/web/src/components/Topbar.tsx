import { NavLink } from "react-router-dom";

import { useAuth } from "../auth/AuthContext";

export function Topbar({ connected }: { connected: boolean }) {
  const { session, logout } = useAuth();
  return (
    <div className="topbar">
      <div className="brand">
        Canary<span className="dot">.</span>
      </div>
      <nav className="nav">
        <NavLink to="/manager" className={({ isActive }) => (isActive ? "active" : "")}>
          Manager
        </NavLink>
        <NavLink to="/dispatch" className={({ isActive }) => (isActive ? "active" : "")}>
          Dispatch
        </NavLink>
        <NavLink to="/sensors" className={({ isActive }) => (isActive ? "active" : "")}>
          Sensors
        </NavLink>
      </nav>
      <div className="spacer" />
      <span className={`live ${connected ? "" : "off"}`}>
        <span className="led" />
        {connected ? "Live" : "Reconnecting…"}
      </span>
      <span className="meta">
        {session?.buildingId} · {session?.role}
      </span>
      <button className="btn" onClick={logout}>
        Sign out
      </button>
    </div>
  );
}
