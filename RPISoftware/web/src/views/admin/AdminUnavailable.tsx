import { ApiError } from "../../api/client";
import { Card } from "../../components/Card";
import { useT } from "../../i18n";

/** The admin API failed: HTTP status + message; 404 means the hub does not serve it yet. */
export function AdminUnavailable({ error }: { error: unknown }) {
  const { t } = useT();
  const status = error instanceof ApiError ? error.status : undefined;
  return (
    <Card>
      <div className="err">
        {t("admin.unavailable", { msg: `${status ? `HTTP ${status} · ` : ""}${(error as Error)?.message ?? ""}` })}
      </div>
      {status === 404 && <div className="muted small">{t("admin.noApi")}</div>}
      {status === 403 && <div className="muted small">{t("admin.forbidden")}</div>}
    </Card>
  );
}
