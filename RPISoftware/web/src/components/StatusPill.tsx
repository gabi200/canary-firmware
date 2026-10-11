import { useT } from "../i18n";
import { stateLabel } from "../lib/labels";

/** Coloured pill; without an explicit `label` the incident state token is translated. */
export function StatusPill({ state, label }: { state: string; label?: string }) {
  const { t } = useT();
  return <span className={`pill ${state}`}>{(label ?? stateLabel(state, t)).replace(/_/g, " ")}</span>;
}
