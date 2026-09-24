import type { ReactNode } from "react";
import { Navigate } from "react-router-dom";

import { Card } from "../components/Card";
import { useAuth } from "./AuthContext";

export function RequireAuth({ children, roles }: { children: ReactNode; roles?: string[] }) {
  const { session } = useAuth();
  if (!session) return <Navigate to="/login" replace />;

  const allowed = !roles || roles.includes(session.role) || session.role === "system_admin";
  if (!allowed) {
    return (
      <div className="content">
        <Card>
          <h3>Access restricted</h3>
          <p className="muted">
            Your role (<b>{session.role}</b>) cannot view this console. Sign in as a manager
            (<b>mihai</b>) or dispatcher (<b>dispecer</b>).
          </p>
        </Card>
      </div>
    );
  }
  return <>{children}</>;
}
