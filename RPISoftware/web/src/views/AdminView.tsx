/**
 * Administration (system_admin, hoa_manager; technician without accounts): accounts, rooms
 * (floor plan editor), devices (new sensors, hardware test), firmware (versions, updates) and the
 * hub's Pis. Tabs are routes: /admin/accounts, /admin/rooms, /admin/devices, /admin/firmware,
 * /admin/hub, and an evacuation what-if on a simulated graph (/admin/whatif). The scope bar on top (apartment /
 * room) applies to every tab but Hub.
 */
import { NavLink, Navigate, useParams } from "react-router-dom";

import { useAuth } from "../auth/AuthContext";
import { ScopeBar } from "../components/ScopeBar";
import { useT, type MsgKey } from "../i18n";
import { AccountsTab } from "./admin/AccountsTab";
import { DevicesTab } from "./admin/DevicesTab";
import { FirmwareTab } from "./admin/FirmwareTab";
import { HubTab } from "./admin/HubTab";
import { RoomsTab } from "./admin/RoomsTab";
import { WhatIfTab } from "./admin/WhatIfTab";

const TABS: { id: string; label: MsgKey }[] = [
  { id: "accounts", label: "admin.tabAccounts" },
  { id: "rooms", label: "admin.tabRooms" },
  { id: "devices", label: "admin.tabDevices" },
  { id: "firmware", label: "admin.tabFirmware" },
  { id: "hub", label: "admin.tabHub" },
  { id: "whatif", label: "admin.tabWhatIf" },
];

export function AdminView() {
  const { t } = useT();
  const { buildingId, session } = useAuth();
  const tabs = session?.role === "technician" ? TABS.filter((x) => x.id !== "accounts") : TABS;
  const tab = useParams()["*"]?.split("/")[0] ?? "";
  if (!tabs.some((x) => x.id === tab)) return <Navigate to={`/admin/${tabs[0].id}`} replace />;

  return (
    <>
      {/* accounts belong to apartments, not rooms: no room row there; the hub's Pis to no apartment */}
      {tab !== "hub" && tab !== "whatif" && <ScopeBar rooms={tab !== "accounts"} />}
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
      {tab === "firmware" && <FirmwareTab />}
      {tab === "hub" && <HubTab />}
      {tab === "whatif" && <WhatIfTab />}
    </>
  );
}
