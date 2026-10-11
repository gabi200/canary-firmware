import { localeOf, translate, type Lang } from "../i18n";

/**
 * Backend timestamps are UTC. On SQLite some endpoints serialize them without a zone
 * designator, which `Date` would read as local time — treat those as UTC too.
 */
export function parseTs(ts: string): number {
  return Date.parse(/(z|[+-]\d\d:?\d\d)$/i.test(ts) ? ts : `${ts}Z`);
}

const toDate = (t: string | number) => new Date(typeof t === "number" ? t : parseTs(t));

/** 7_980_000 -> "2 h 13 min" (units in the active language). */
export function fmtDuration(ms: number, lang: Lang): string {
  const [us, umin, uh, ud] = (["unit.s", "unit.min", "unit.h", "unit.d"] as const).map((k) =>
    translate(lang, k),
  );
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s} ${us}`;
  const m = Math.floor(s / 60);
  if (m < 60) return s % 60 ? `${m} ${umin} ${s % 60} ${us}` : `${m} ${umin}`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h} ${uh} ${m % 60} ${umin}`;
  return `${Math.floor(h / 24)} ${ud} ${h % 24} ${uh}`;
}

export function fmtAgo(ts: string | null | undefined, lang: Lang): string {
  if (!ts) return translate(lang, "time.never");
  const ms = Date.now() - parseTs(ts);
  if (Number.isNaN(ms)) return "—";
  return ms < 1000
    ? translate(lang, "time.justNow")
    : translate(lang, "time.ago", { d: fmtDuration(ms, lang) });
}

/** Local wall-clock time (hh:mm:ss, or hh:mm) of a backend timestamp or epoch ms. */
export function fmtClock(t: string | number, lang: Lang, seconds = true): string {
  return toDate(t).toLocaleTimeString(localeOf(lang), {
    hour: "2-digit",
    minute: "2-digit",
    ...(seconds ? { second: "2-digit" } : {}),
  });
}

/** Local date and time of a backend timestamp or epoch ms. */
export function fmtDateTime(t: string | number, lang: Lang): string {
  return toDate(t).toLocaleString(localeOf(lang));
}

/** Chart axis tick for a window of `minutes`: "14:30", or "Fri 9" / "vin. 9" beyond a day. */
export function fmtAxisTime(ms: number, lang: Lang, minutes: number): string {
  if (minutes > 1440) {
    return new Date(ms).toLocaleDateString(localeOf(lang), { weekday: "short", day: "numeric" });
  }
  return fmtClock(ms, lang, false);
}

/** Chart tooltip time: hh:mm:ss, with weekday and date for windows beyond a day. */
export function fmtTooltipTime(ms: number, lang: Lang, minutes: number): string {
  if (minutes > 1440) {
    return new Date(ms).toLocaleString(localeOf(lang), {
      weekday: "short",
      day: "numeric",
      month: "short",
      hour: "2-digit",
      minute: "2-digit",
    });
  }
  return fmtClock(ms, lang);
}

const TICK_STEPS_MIN = [1, 2, 5, 10, 15, 30, 60, 120, 180, 240, 360, 720, 1440];

/** At most ~6 axis ticks on round local clock times (whole local days for a week). */
export function timeTicks(from: number, to: number): number[] {
  const stepMin = TICK_STEPS_MIN.find((m) => (to - from) / (m * 60_000) <= 6) ?? 1440;
  const step = stepMin * 60_000;
  const tz = new Date(from).getTimezoneOffset() * 60_000;
  const ticks: number[] = [];
  for (let t = Math.ceil((from - tz) / step) * step + tz; t <= to; t += step) ticks.push(t);
  return ticks;
}
