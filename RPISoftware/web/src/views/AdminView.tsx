/**
 * Administration (system_admin, hoa_manager; technician without accounts): accounts, rooms
 * (floor plan editor) and devices (new sensors, hardware test). Tabs are routes: /admin/accounts, /admin/rooms, /admin/devices. The scope bar
 * on top (apartment / room) applies to every tab.
 */
import { NavLink, Navigate, useParams } from "react-router-dom";

import { useAuth } from "../auth/AuthContext";
import { ScopeBar } from "../components/ScopeBar";
import { useT, type MsgKey } from "../i18n";
import { AccountsTab } from "./admin/AccountsTab";
import { DevicesTab } from "./admin/DevicesTab";
import { RoomsTab } from "./admin/RoomsTab";

const TABS: { id: string; label: MsgKey }[] = [
  { id: "accounts", label: "admin.tabAccounts" },
  { id: "rooms", label: "admin.tabRooms" },
  { id: "devices", label: "admin.tabDevices" },
];

export function AdminView() {
  const { t } = useT();
  const { buildingId, session } = useAuth();
  const tabs = session?.role === "technician" ? TABS.filter((x) => x.id !== "accounts") : TABS;
  const tab = useParams()["*"]?.split("/")[0] ?? "";
  if (!tabs.some((x) => x.id === tab)) return <Navigate to={`/admin/${tabs[0].id}`} replace />;

  return (
    <>
      {/* accounts belong to apartments, not rooms: no room row there */}
      <ScopeBar rooms={tab !== "accounts"} />
      <div className="page-head">
        <h2>{t("admin.title")}</h2>
        <span className="muted">{t("admin.subtitle", { id: buildingId })}</span>
      </div>
      <nav className="admin-tabs" aria-label={t("admin.title")}>
        {tabs.map((x) => (
          <NavLink key={x.id} to={`/admin/${x.id}`} className={({ isActive }) => (isActive ? "active" : "")}>
            {t(x.label)}
          </NavLink>
        ))}
      </nav>
      {tab === "accounts" && <AccountsTab />}
      {tab === "rooms" && <RoomsTab />}
      {tab === "devices" && <DevicesTab />}
    </>
  );
}
