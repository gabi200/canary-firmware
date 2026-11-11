import { NavLink, useLocation } from "react-router-dom";

import { useHubMode, useIncidents, useSetHubMode } from "../api/hooks";
import { useAuth } from "../auth/AuthContext";
import { useT, type MsgKey } from "../i18n";
import { tokenLabel } from "../lib/labels";
import { BuildingIcon, SensorIcon, SignOutIcon, SirenIcon, SlidersIcon } from "./Icons";
import { LangToggle } from "./LangToggle";
import { ThemeToggle } from "./ThemeToggle";

const active = ({ isActive }: { isActive: boolean }) => (isActive ? "active" : "");

/** Open incidents of the building, on the Dispatch destination: visible from every page. */
function IncidentCount() {
  const { t } = useT();
  const n = (useIncidents(true).data ?? []).length;
  if (n === 0) return null;
  return (
    <span className="nav-count" title={t("common.activeIncidents")}>
      <span className="sr-only">{t("common.activeIncidents")}: </span>
      {n}
    </span>
  );
}

/** Left rail: brand, destinations, then connection, building, role and sign out. */
export function Rail({ connected }: { connected: boolean }) {
  const { session, buildingId, logout } = useAuth();
  const { t } = useT();
  const role = session?.role;
  return (
    <aside className="rail">
      <div className="brand">
        Canary<span className="dot">.</span>
      </div>
      <nav className="nav">
        {/* a technician installs rooms and sensors: no incident consoles */}
        {role !== "technician" && (
          <>
            <NavLink to="/manager" className={active}>
              <BuildingIcon />
              {t("nav.manager")}
            </NavLink>
            <NavLink to="/dispatch" className={active}>
              <SirenIcon />
              {t("nav.dispatch")}
              <IncidentCount />
            </NavLink>
          </>
        )}
        <NavLink to="/sensors" className={active}>
          <SensorIcon />
          {t("nav.sensors")}
        </NavLink>
        {(role === "system_admin" || role === "hoa_manager" || role === "technician") && (
          <NavLink to="/admin" className={active}>
            <SlidersIcon />
            {t("nav.admin")}
          </NavLink>
        )}
      </nav>
      <div className="rail-foot">
        <span className={`live ${connected ? "" : "off"}`}>
          <span className="led" />
          <span>{connected ? t("topbar.live") : t("topbar.reconnecting")}</span>
        </span>
        <div className="rail-id">
          <b>{buildingId}</b>
          <span>{session ? tokenLabel(t, "role", session.role) : ""}</span>
        </div>
        <button className="btn small-btn rail-signout" onClick={logout} aria-label={t("topbar.signOut")}>
          <SignOutIcon />
          <span className="rail-signout-label">{t("topbar.signOut")}</span>
        </button>
      </div>
    </aside>
  );
}

const TITLES: [string, MsgKey][] = [
  ["/manager", "nav.manager"],
  ["/dispatch", "nav.dispatch"],
  ["/sensors", "nav.sensors"],
  ["/admin", "nav.admin"],
];

/** Utility bar over the content: where you are, hub mode, language and theme. */
export function Topbar() {
  const { session } = useAuth();
  const hubMode = useHubMode();
  const setMode = useSetHubMode();
  const canSwitch = session?.role === "system_admin" || session?.role === "hoa_manager";
  const { t } = useT();
  const { pathname } = useLocation();
  const title = TITLES.find(([path]) => pathname.startsWith(path))?.[1];
  return (
    <header className="topbar">
      <h1 className="topbar-title">{title ? t(title) : ""}</h1>
      <div className="spacer" />
      {setMode.isError && <span className="err">{t("mode.failed")}</span>}
      {hubMode?.mode === "demo" && <span className="pill mode-badge">{t("mode.badge")}</span>}
      {canSwitch && hubMode && (
        <div className="seg mode-switch" role="group" aria-label={t("mode.label")}>
          {(["demo", "real"] as const).map((m) => (
            <button
              key={m}
              type="button"
              className={hubMode.mode === m ? "active" : ""}
              aria-pressed={hubMode.mode === m}
              disabled={setMode.isPending}
              onClick={() => hubMode.mode !== m && setMode.mutate(m)}
            >
              {t(`mode.${m}`)}
            </button>
          ))}
        </div>
      )}
      <LangToggle />
      <ThemeToggle />
    </header>
  );
}
