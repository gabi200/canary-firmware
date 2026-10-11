import type { ReactNode } from "react";
import { Navigate } from "react-router-dom";

import { Card } from "../components/Card";
import { rich, useT } from "../i18n";
import { tokenLabel } from "../lib/labels";
import { useAuth } from "./AuthContext";

export function RequireAuth({ children, roles }: { children: ReactNode; roles?: string[] }) {
  const { session } = useAuth();
  const { t } = useT();
  if (!session) return <Navigate to="/login" replace />;

  const allowed = !roles || roles.includes(session.role) || session.role === "system_admin";
  if (!allowed) {
    return (
      <div className="content">
        <Card>
          <h3>{t("auth.restrictedTitle")}</h3>
          <p className="muted">
            {rich(t("auth.restrictedBody"), {
              role: <b>{tokenLabel(t, "role", session.role)}</b>,
              manager: <b>mihai</b>,
              dispatcher: <b>dispecer</b>,
            })}
          </p>
        </Card>
      </div>
    );
  }
  return <>{children}</>;
}
