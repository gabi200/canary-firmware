import { useT } from "../i18n";
import { tokenLabel } from "../lib/labels";

const CLS: Record<string, string> = {
  genuine: "alarm",
  likely_benign: "detection",
  transient: "detection",
  drift: "detection",
  micro_leak_trend: "detection",
};

/** Renders the false-alarm-reduction assessment as a pill (null for insufficient/none). */
export function SignalBadge({ cls }: { cls: string | null }) {
  const { t } = useT();
  if (!cls || cls === "insufficient_data") return null;
  return <span className={`pill ${CLS[cls] ?? ""}`}>{tokenLabel(t, "signal", cls)}</span>;
}
