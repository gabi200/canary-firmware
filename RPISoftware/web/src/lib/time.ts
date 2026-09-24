/**
 * Backend timestamps are UTC. On SQLite some endpoints serialize them without a zone
 * designator, which `Date` would read as local time — treat those as UTC too.
 */
export function parseTs(ts: string): number {
  return Date.parse(/(z|[+-]\d\d:?\d\d)$/i.test(ts) ? ts : `${ts}Z`);
}

/** 7_980_000 -> "2 h 13 min". */
export function fmtDuration(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return s % 60 ? `${m} min ${s % 60} s` : `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h} h ${m % 60} min`;
  return `${Math.floor(h / 24)} d ${h % 24} h`;
}

export function fmtAgo(ts: string | null | undefined): string {
  if (!ts) return "never";
  const ms = Date.now() - parseTs(ts);
  if (Number.isNaN(ms)) return "—";
  return ms < 1000 ? "just now" : `${fmtDuration(ms)} ago`;
}

/** Local wall-clock time (hh:mm:ss) of a backend timestamp or epoch ms. */
export function fmtClock(t: string | number): string {
  return new Date(typeof t === "number" ? t : parseTs(t)).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}
