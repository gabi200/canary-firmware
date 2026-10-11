import type { Signature } from "../api/types";
import { useT } from "../i18n";
import { tokenLabel } from "../lib/labels";

const CLS: Record<string, string> = {
  smouldering_fire: "alarm",
  flaming_fire: "alarm",
  gas_leak: "alarm",
  steam: "detection",
  cooking: "detection",
  aerosol: "detection",
};

const pct = (value: number) => `${Math.round(value * 100)}%`;

/** Renders the hazard signature as a pill with its evidence on hover (null for normal/unknown).
 *  Evidence lines are backend text (localized by the backend via Accept-Language). */
export function SignatureBadge({ signature }: { signature: Signature | null }) {
  const { t } = useT();
  if (!signature || signature.label === "normal" || signature.label === "unknown") return null;
  const lines = [...signature.evidence];
  if (signature.shadow_label && signature.shadow_confidence !== null) {
    lines.push(
      t("signature.shadow", {
        label: tokenLabel(t, "signature", signature.shadow_label),
        pct: pct(signature.shadow_confidence),
      }),
    );
  }
  return (
    <span className={`pill ${CLS[signature.label] ?? ""}`} title={lines.join("\n")} style={{ marginLeft: 6 }}>
      {tokenLabel(t, "signature", signature.label)} · {pct(signature.confidence)}
    </span>
  );
}
