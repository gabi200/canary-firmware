import { useFusionExplanation } from "../api/hooks";
import type { EvidenceItem } from "../api/types";
import { useT, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import { prettyId, sensorLabel, tokenLabel } from "../lib/labels";
import { fmtAgo, fmtDuration } from "../lib/time";
import { Card } from "./Card";
import { StatusPill } from "./StatusPill";

function evidenceLabel(value: string, t: TFn): string {
  const fresh = /^fresh_([^:]+):(.+)$/.exec(value);
  if (fresh) return t("fusion.freshEvidence", { sensor: sensorLabel(fresh[1], t), device: fresh[2] });
  return tokenLabel(t, "fusion.evidence", value);
}

function EvidenceList({ title, items, label = evidenceLabel }: {
  title: string;
  items: string[];
  label?: (value: string, t: TFn) => string;
}) {
  const { t } = useT();
  return (
    <section className="fusion-evidence">
      <h4>{title}</h4>
      {items.length ? (
        <ul>{items.map((item, index) => <li key={`${item}-${index}`}>{label(item, t)}</li>)}</ul>
      ) : (
        <div className="muted small">{t("fusion.none")}</div>
      )}
    </section>
  );
}

const ROLES = ["supporting", "contradicting", "context", "missing"] as const;

function itemLabel(item: EvidenceItem, t: TFn): string {
  const room = item.zone_id ? prettyId(item.zone_id) : "";
  if (item.source === "sensor_trust")
    return t("fusion.item.trust", {
      device: item.subject,
      state: tokenLabel(t, "trust.state", item.status),
      reason: tokenLabel(t, "trust.reason", item.reason),
    });
  if (item.source === "motion") return t("fusion.item.motion", { room, state: tokenLabel(t, "motion.state", item.status) });
  return t("fusion.item.normal", {
    room,
    sensor: sensorLabel(item.subject, t),
    status: tokenLabel(t, "normal.status", item.status),
  });
}

/** Room evidence from sensor trust, motion and room normals. Labels only: none of it moves the score. */
function EvidenceItems({ items }: { items: EvidenceItem[] }) {
  const { t } = useT();
  return (
    <section className="fusion-items">
      <h4>{t("fusion.items")}</h4>
      <div className="muted small">{t("fusion.itemsNote")}</div>
      {items.length ? (
        <div className="fusion-grid">
          {ROLES.map((role) => {
            const mine = items.filter((item) => item.role === role);
            return mine.length ? (
              <section className="fusion-evidence" key={role}>
                <h4>{t(`fusion.role.${role}`)}</h4>
                <ul>
                  {mine.map((item, index) => (
                    <li key={`${item.source}-${item.zone_id}-${item.subject}-${index}`}>
                      {itemLabel(item, t)}
                      {item.strength === "weak" && <span className="muted small"> · {t("fusion.weak")}</span>}
                    </li>
                  ))}
                </ul>
              </section>
            ) : null;
          })}
        </div>
      ) : (
        <div className="muted small">{t("fusion.none")}</div>
      )}
    </section>
  );
}

/** Current advisory evidence only. It never changes, delays or suppresses an incident. */
export function FusionExplanationPanel({ incidentId }: { incidentId: string }) {
  const { t, lang } = useT();
  const fusion = useFusionExplanation(incidentId);
  const data = fusion.data;

  return (
    <Card title={t("fusion.title")}>
      {!data ? (
        <div className={fusion.isError ? "err" : "muted small"}>
          {fusion.isError ? t("fusion.unavailable") : t("fusion.loading")}
        </div>
      ) : (
        <>
          <div className="fusion-head">
            <div className="fusion-score">
              <strong>{t("fusion.scoreValue", { score: fmtNumber(data.score, lang, 2, true) })}</strong>
              <span>{t("fusion.score")}</span>
            </div>
            <div className="fusion-summary small">
              <div>
                {t("fusion.classification")}: <b>{tokenLabel(t, "signal", data.classification)}</b>
              </div>
              <div>{t("fusion.witnesses", { n: data.fresh_witnesses })}</div>
              <div className="muted">{t("fusion.assessed", { ago: fmtAgo(data.assessed_ts, lang) })}</div>
            </div>
          </div>
          <div className="muted small fusion-note">{t("fusion.note")}</div>

          <div className="fusion-grid">
            <EvidenceList title={t("fusion.supporting")} items={data.supporting_evidence} />
            <EvidenceList title={t("fusion.contradicting")} items={data.contradicting_evidence} />
            <EvidenceList
              title={t("fusion.missing")}
              items={data.missing_inputs}
              label={(item, translate) => sensorLabel(item, translate)}
            />
            <EvidenceList
              title={t("fusion.overrides")}
              items={data.active_overrides}
              label={(item, translate) => tokenLabel(translate, "fusion.override", item)}
            />
          </div>

          {data.evidence_items && <EvidenceItems items={data.evidence_items} />}

          <section className="fusion-inputs">
            <h4>{t("fusion.inputs")}</h4>
            {data.inputs.length ? (
              data.inputs.map((input) => (
                <div className="row" key={input.name}>
                  <span className="grow">
                    {input.name === "signature" ? t("fusion.input.signature") : sensorLabel(input.name, t)}
                  </span>
                  <span className="muted small">
                    {input.age_seconds == null
                      ? t("fusion.inputNever")
                      : t("fusion.inputAge", { age: fmtDuration(input.age_seconds * 1000, lang) })}
                  </span>
                  <StatusPill state={input.status} label={t(`fusion.input.${input.status}`)} />
                </div>
              ))
            ) : (
              <div className="muted small">{t("fusion.none")}</div>
            )}
          </section>
        </>
      )}
    </Card>
  );
}
