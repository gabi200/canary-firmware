/**
 * Each room against its own learned normal (frozen median / MAD per metric, hour buckets once there
 * is enough history). Evidence only: the score is a heuristic, not a probability, and the alarm
 * thresholds are unchanged. Seed references are labelled as simulated.
 */
import { useZoneNormal } from "../api/hooks";
import type { NormalStatus } from "../api/types";
import { useT } from "../i18n";
import { fmtNumber } from "../lib/format";
import { Card } from "./Card";

const PILL: Record<NormalStatus, string> = {
  usual: "quiet",
  unusual_high: "attention",
  unusual_low: "attention",
  learning: "unknown",
  no_recent_data: "unknown",
};

export function ZoneNormalCard() {
  const { t, lang } = useT();
  const normal = useZoneNormal();
  if (normal.fetchStatus === "idle" && !normal.data) return null; // not asked for this role
  const rows = (normal.data?.zones ?? []).flatMap((z) => z.metrics.map((m) => ({ zone: z.label || z.zone_id, m })));
  const num = (v: number) => fmtNumber(v, lang, v < 10 ? 1 : 0);
  return (
    <Card title={t("normal.title")}>
      <div className="muted small" style={{ marginBottom: 8 }}>{t("normal.caveat")}</div>
      {normal.isError && <div className="muted small">{t("normal.unavailable")}</div>}
      {!normal.data && !normal.isError && <div className="muted small">{t("common.loading")}</div>}
      {normal.data && rows.length === 0 && <div className="muted small">{t("normal.none")}</div>}
      {rows.map(({ zone, m }) => (
        <div key={`${zone}-${m.sensor_type}`} className="row" style={{ marginBottom: 6, flexWrap: "wrap" }}>
          <div className="grow">
            {zone} · {t(`sensor.${m.sensor_type}` as Parameters<typeof t>[0])}
            <div className="muted small">
              {m.status === "learning"
                ? t("normal.learning", { n: m.n })
                : m.value != null && m.median != null && m.score != null
                  ? t("normal.vs", { value: num(m.value), median: num(m.median), score: fmtNumber(m.score, lang, 1) })
                  : null}
              {m.hour != null && m.hour >= 0 && <> · {t("normal.hour", { hour: m.hour })}</>}
              {m.source === "seed" && <> · <span className="pill unknown">{t("normal.seed")}</span></>}
            </div>
          </div>
          <span className={`pill ${PILL[m.status]}`}>{t(`normal.status.${m.status}`)}</span>
        </div>
      ))}
    </Card>
  );
}
