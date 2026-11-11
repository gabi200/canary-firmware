import { Navigate, Outlet, Route, Routes } from "react-router-dom";

import { useAuth } from "./auth/AuthContext";
import { JoinPage } from "./auth/JoinPage";
import { LoginPage } from "./auth/LoginPage";
import { useT } from "./i18n";
import { RequireAuth } from "./auth/RequireAuth";
import { RealAlarmBanner } from "./components/RealAlarmBanner";
import { ClassificationAlerts } from "./components/ClassificationAlerts";
import { Rail, Topbar } from "./components/Topbar";
import { useIncidentSocket } from "./realtime/useIncidentSocket";
import { AdminView } from "./views/AdminView";
import { DispatchView } from "./views/DispatchView";
import { ManagerView } from "./views/ManagerView";
import { SensorsView } from "./views/SensorsView";

function AuthedLayout() {
  const { session, token, buildingId, modeReady } = useAuth();
  const { t } = useT();
  // Hook is always called (stable order); it no-ops until a token exists, and waits for the
  // first mode answer so the socket does not open on the wrong building first.
  const { connected } = useIncidentSocket(buildingId, modeReady ? token : null);
  if (!session) return <Navigate to="/login" replace />;
  // no screen renders before the mode is known: Real data must not flash during Demo
  if (!modeReady) return <div className="boot">{t("common.loading")}</div>;
  return (
    <div className="app">
      <Rail connected={connected} />
      <div className="main">
        <Topbar />
        <RealAlarmBanner />
        <ClassificationAlerts />
        <Outlet />
      </div>
    </div>
  );
}

function HomeRedirect() {
  const { session } = useAuth();
  if (!session) return <Navigate to="/login" replace />;
  const home: Record<string, string> = { dispatcher_external: "/dispatch", technician: "/admin/rooms" };
  return <Navigate to={home[session.role] ?? "/manager"} replace />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      {/* public: household invitation links opened on phones (no login, no API calls) */}
      <Route path="/join/:code" element={<JoinPage />} />
      <Route element={<AuthedLayout />}>
        <Route
          path="/manager"
          element={
            <RequireAuth roles={["hoa_manager"]}>
              <div className="content">
                <ManagerView />
              </div>
            </RequireAuth>
          }
        />
        <Route
          path="/dispatch"
          element={
            <RequireAuth roles={["dispatcher_external", "hoa_manager"]}>
              <div className="content">
                <DispatchView />
              </div>
            </RequireAuth>
          }
        />
        <Route
          path="/sensors"
          element={
            <RequireAuth roles={["hoa_manager", "dispatcher_external", "technician"]}>
              <div className="content">
                <SensorsView />
              </div>
            </RequireAuth>
          }
        />
        <Route
          path="/admin/*"
          element={
            <RequireAuth roles={["hoa_manager", "technician"]}>
              <div className="content">
                <AdminView />
              </div>
            </RequireAuth>
          }
        />
      </Route>
      <Route path="/" element={<HomeRedirect />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
