import { Fragment, type ReactNode } from "react";
import { useT } from "../i18n";
import { SafetySign, hazardAdviceSigns, hazardSign, signName } from "./SafetySigns";

/** The incident banner: a contained panel in the state colour. Pictograms and the headline
 *  (with its classification tags) sit in the head, the advice signs in a band at the foot.
 *  Evacuation adds the exit pictogram (the one pulsing element) and a slim hazard-tape strip. */
export function IncidentBanner({
  state,
  hazardType,
  hazardTitle,
  headline,
  sub,
  tags,
  status,
  advice,
}: {
  state: string;
  hazardType: string;
  hazardTitle?: string;
  headline: string;
  /** incident line; split on " · " so it only wraps between segments */
  sub: string;
  tags?: ReactNode;
  status?: ReactNode;
  advice?: boolean;
}) {
  const { t, lang } = useT();
  const evacuation = state === "evacuation";
  return (
    <div className={`sitrep state-${state} ${evacuation ? "evac" : ""}`} style={{ marginBottom: 16 }}>
      <div className="sitrep-head">
        <div className="sitrep-signs">
          {evacuation && <SafetySign code="E002" size={48} className="safety-sign pulse" title={t("evac.nowTitle")} />}
          <SafetySign code={hazardSign(hazardType)} size={48} className="safety-sign" title={hazardTitle} />
        </div>
        <div className="sitrep-body">
          <div className="sitrep-title">
            <h2>{headline}</h2>
            {tags && <div className="sitrep-tags">{tags}</div>}
          </div>
          <div className="sub">{segments(sub)}</div>
          <div className="sitrep-status">{status}</div>
        </div>
      </div>
      {advice && (
        <div className="sitrep-advice">
          {hazardAdviceSigns(hazardType).map((code) => (
            <span key={code} className="sign-chip">
              <SafetySign code={code} size={32} className="safety-sign" />
              {signName(code, lang)}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}

function segments(line: string): ReactNode[] {
  const parts = line.split(" · ");
  return parts.map((part, i) => (
    <Fragment key={i}>
      <span className="sub-seg">{i < parts.length - 1 ? `${part} ·` : part}</span>{" "}
    </Fragment>
  ));
}
