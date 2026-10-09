import type { Signature } from "../api/types";

const LABELS: Record<string, { text: string; cls: string }> = {
  smouldering_fire: { text: "smouldering fire", cls: "alarm" },
  flaming_fire: { text: "flaming fire", cls: "alarm" },
  gas_leak: { text: "gas leak", cls: "alarm" },
  steam: { text: "steam", cls: "detection" },
  cooking: { text: "cooking", cls: "detection" },
  aerosol: { text: "aerosol / incense", cls: "detection" },
};

const pct = (value: number) => `${Math.round(value * 100)}%`;

/** Renders the hazard signature as a pill with its evidence on hover (null for normal/unknown). */
export function SignatureBadge({ signature }: { signature: Signature | null }) {
  if (!signature || signature.label === "normal" || signature.label === "unknown") return null;
  const m = LABELS[signature.label] ?? { text: signature.label.replace(/_/g, " "), cls: "" };
  const lines = [...signature.evidence];
  if (signature.shadow_label && signature.shadow_confidence !== null) {
    lines.push(`model (shadow): ${signature.shadow_label.replace(/_/g, " ")} ${pct(signature.shadow_confidence)}`);
  }
  return (
    <span className={`pill ${m.cls}`} title={lines.join("\n")} style={{ marginLeft: 6 }}>
      {m.text} · {pct(signature.confidence)}
    </span>
  );
}
