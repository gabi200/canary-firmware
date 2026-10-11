import { useT } from "../i18n";
import { fmtNumber } from "../lib/format";
import { rssiQuality } from "../lib/metrics";

/** 0-4 bars from the RSSI the device reports (dashboard heuristic, like rssiQuality). */
export function rssiBars(dbm: number): number {
  return dbm >= -55 ? 4 : dbm >= -67 ? 3 : dbm >= -75 ? 2 : dbm >= -85 ? 1 : 0;
}

/** Signal bars + "-58 dBm"; an em dash without a reading. */
export function WifiBars({ rssi }: { rssi: number | null }) {
  const { t, lang } = useT();
  if (rssi == null) return <span className="muted">—</span>;
  const bars = rssiBars(rssi);
  const quality = rssiQuality(rssi);
  const dbm = fmtNumber(rssi, lang, 0);
  return (
    <span className={`wifi-bars q-${quality}`} title={t("rssi.aria", { quality: t(`rssi.${quality}`), dbm })}>
      <svg viewBox="0 0 20 16" width="20" height="16" aria-hidden="true" focusable="false">
        {[0, 1, 2, 3].map((i) => (
          <rect key={i} x={i * 5} y={12 - i * 4} width="3.4" height={4 + i * 4} rx="1" className={i < bars ? "on" : "off"} />
        ))}
      </svg>
      <span className="wifi-dbm">{dbm} dBm</span>
      <span className="sr-only">{t(`rssi.${quality}`)}</span>
    </span>
  );
}
