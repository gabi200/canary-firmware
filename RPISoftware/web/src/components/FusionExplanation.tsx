import { useFusionExplanation } from "../api/hooks";
import { useT, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import { sensorLabel, tokenLabel } from "../lib/labels";
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
