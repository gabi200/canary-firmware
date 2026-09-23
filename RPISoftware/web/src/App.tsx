import { Navigate, Outlet, Route, Routes } from "react-router-dom";

import { useAuth } from "./auth/AuthContext";
import { LoginPage } from "./auth/LoginPage";
import { RequireAuth } from "./auth/RequireAuth";
import { Topbar } from "./components/Topbar";
import { useIncidentSocket } from "./realtime/useIncidentSocket";
import { DispatchView } from "./views/DispatchView";
import { ManagerView } from "./views/ManagerView";

function AuthedLayout() {
  const { session, token, buildingId } = useAuth();
  // Hook is always called (stable order); it no-ops until a token exists.
  const { connected } = useIncidentSocket(buildingId, token);
  if (!session) return <Navigate to="/login" replace />;
  return (
    <div className="app">
      <Topbar connected={connected} />
      <Outlet />
    </div>
  );
}

function HomeRedirect() {
  const { session } = useAuth();
  if (!session) return <Navigate to="/login" replace />;
  return <Navigate to={session.role === "dispatcher_external" ? "/dispatch" : "/manager"} replace />;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
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
      </Route>
      <Route path="/" element={<HomeRedirect />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
