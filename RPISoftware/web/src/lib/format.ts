import { localeOf, type Lang, type TFn } from "../i18n";

const cache = new Map<string, Intl.NumberFormat>();

/**
 * A measured value in the active locale: RO "22,4", EN "22.4". `digits` is the maximum number
 * of decimals (`fixed`: always that many). No digit grouping: device values stay short
 * (ADC counts ≤ 4095) and "4.095" would read as a decimal to half the audience.
 */
/** A canonical reading's value with its unit token ("persons_est" -> people, "bool" -> yes/no). */
export function fmtReading(value: number, units: string, lang: Lang, t: TFn): string {
  if (units === "persons_est") return t("dispatch.people", { n: fmtNumber(value, lang, 0) });
  if (units === "bool") return value ? t("common.yes") : t("common.no");
  const unit = units === "ug/m3" ? "µg/m³" : units === "adc" ? "ADC" : units;
  return `${fmtNumber(value, lang, 1)} ${unit}`;
}

export function fmtNumber(value: number, lang: Lang, digits = 1, fixed = false): string {
  const key = `${lang}|${digits}|${fixed}`;
  let f = cache.get(key);
  if (!f) {
    f = new Intl.NumberFormat(localeOf(lang), {
      maximumFractionDigits: digits,
      minimumFractionDigits: fixed ? digits : 0,
      useGrouping: false,
    });
    cache.set(key, f);
  }
  return f.format(value);
}

/** Natural, case-insensitive order: "Ap. 2" before "Ap. 10". */
export const natural = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
