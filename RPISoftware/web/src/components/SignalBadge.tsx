const LABELS: Record<string, { text: string; cls: string }> = {
  genuine: { text: "genuine", cls: "alarm" },
  likely_benign: { text: "held · likely benign", cls: "detection" },
  transient: { text: "held · transient", cls: "detection" },
  drift: { text: "sensor drift", cls: "detection" },
  micro_leak_trend: { text: "micro-leak trend", cls: "detection" },
};

/** Renders the false-alarm-reduction assessment as a pill (null for insufficient/none). */
export function SignalBadge({ cls }: { cls: string | null }) {
  if (!cls || cls === "insufficient_data") return null;
  const m = LABELS[cls] ?? { text: cls.replace(/_/g, " "), cls: "" };
  return <span className={`pill ${m.cls}`}>{m.text}</span>;
}
