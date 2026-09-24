export function StatusPill({ state, label }: { state: string; label?: string }) {
  return <span className={`pill ${state}`}>{(label ?? state).replace(/_/g, " ")}</span>;
}
