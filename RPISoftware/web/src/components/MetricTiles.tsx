import type { NodeOut } from "../api/types";
import { useT, type Lang, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import {
  COLORS,
  METRICS,
  channelTrust,
  currentValue,
  keyOf,
  rssiQuality,
  type Level,
  type Metric,
  type Row,
} from "../lib/metrics";
import { pick, pickNum } from "../lib/nodes";
import { Sparkline } from "./Sparkline";

interface Tile {
  id: string;
  label: string;
  value: string | null;
  unit?: string;
  approx?: boolean;
  level: Level;
  sub?: string;
  hint?: string;
  spark?: { key: string; color: string; binary?: boolean; zeroBased?: boolean; pad?: number };
}

/** A numeric metric as the device reports it now: value, device-threshold level, caption. */
function metricTile(m: Metric, doc: unknown, t: TFn, lang: Lang): Tile {
  const { value, trust } = currentValue(m, doc);
  const level: Level = value == null ? "unknown" : m.level(value, doc);
  let sub: string | undefined;
  if (trust !== "ok") {
    sub = t(`tile.${trust}`);
  } else if (m.refs) {
    const [lo, hi] = m.refs.map((r) => pickNum(doc, r.path));
    if (lo != null && hi != null) {
      sub =
        m.field === "sensor.adc"
          ? t("tile.wetDry", { wet: fmtNumber(hi, lang, 0), dry: fmtNumber(lo, lang, 0) })
          : t("tile.thresholds", { warn: fmtNumber(lo, lang, m.digits), danger: fmtNumber(hi, lang, m.digits) });
    }
  } else if (m.approx) {
    sub = t("tile.inPmSensor");
  } else if (m.field === "wifi.rssi" && value != null) {
    sub = t(`rssi.${rssiQuality(value)}`);
  }
  // hazard colours win over the metric colour so a rising value stands out in the sparkline too
  const color = level === "danger" || level === "attention" ? (level === "danger" ? COLORS.red : COLORS.amber) : m.color;
  return {
    id: m.field,
    label: t(m.label),
    value: value == null ? null : fmtNumber(value, lang, m.digits, m.fixed),
    unit: m.unit,
    approx: m.approx,
    level,
    sub,
    hint: m.hint ? t(m.hint) : undefined,
    spark: { key: keyOf(m.field), color, zeroBased: m.zeroBased, pad: m.pad },
  };
}

/** Water: probe state + latch. Wet is the hazard; a latch on a dry probe still needs a look. */
function leakTile(doc: unknown, t: TFn): Tile {
  const trust = channelTrust(doc, "sensor");
  const state = pick(doc, "sensor.state");
  const latched = pick(doc, "leak_latched") === true;
  const base = {
    id: "leak",
    label: t("tile.leak"),
    spark: { key: keyOf("leak_latched"), color: COLORS.red, binary: true },
  };
  if (trust !== "ok") return { ...base, value: null, level: "unknown", sub: t(`tile.${trust}`) };
  if (state === "wet") return { ...base, value: t("leak.wet"), level: "danger" };
  if (latched) return { ...base, value: t("leak.latched"), level: "attention", sub: t("leak.latchedSub") };
  return { ...base, value: state === "dry" ? t("leak.dry") : null, level: state === "dry" ? "ok" : "unknown" };
}

/** Water: shut-off valve as applied by the relay; closed means the water is off. */
function valveTile(doc: unknown, t: TFn): Tile {
  const applied = pick(doc, "valve.applied");
  const requested = pick(doc, "valve.requested");
  const word = (v: unknown) => (v === "closed" ? t("valve.closed") : v === "open" ? t("valve.open") : null);
  const sub =
    requested && requested !== applied
      ? t("valve.requested", { state: (word(requested) ?? String(requested)).toLowerCase() })
      : pick(doc, "valve.relay_active") === true
        ? t("valve.relay")
        : undefined;
  return {
    id: "valve",
    label: t("tile.valve"),
    value: word(applied),
    level: applied === "closed" ? "attention" : applied === "open" ? "ok" : "unknown",
    sub,
    spark: { key: keyOf("valve.applied"), color: COLORS.amber, binary: true },
  };
}

function tilesFor(node: NodeOut, t: TFn, lang: Lang): Tile[] {
  const doc = node.status;
  if (node.kind === "water") {
    return [metricTile(METRICS.probe, doc, t, lang), leakTile(doc, t), valveTile(doc, t), metricTile(METRICS.rssi, doc, t, lang)];
  }
  return [
    METRICS.co,
    METRICS.pm25,
    METRICS.pm10,
    METRICS.pm1,
    METRICS.temperature,
    METRICS.humidity,
    METRICS.gas,
    METRICS.rssi,
  ].map((m) => metricTile(m, doc, t, lang));
}

/** Home-Assistant-style tiles: current value (latest status document) + sparkline of the
 *  selected window. Values of an offline / stale node are dimmed (last report). */
export function MetricTiles({
  node,
  rows,
  from,
  to,
}: {
  node: NodeOut;
  rows: Row[];
  from: number;
  to: number;
}) {
  const { t, lang } = useT();
  const stale = !node.online || !!node.analysis?.stale;
  return (
    <div className="tiles">
      {tilesFor(node, t, lang).map((tile) => (
        <div
          key={tile.id}
          className={`tile lvl-${tile.level} ${stale ? "stale" : ""}`}
          role="group"
          aria-label={tile.label}
          title={tile.hint}
        >
          <div className="tile-head">
            <span className="tile-label">{tile.label}</span>
            {(tile.level === "ok" || tile.level === "attention" || tile.level === "danger") && (
              <span className={`lvl ${tile.level}`} />
            )}
          </div>
          <div className={`tile-value t-${tile.level}`}>
            {tile.value == null ? (
              "—"
            ) : (
              <>
                {tile.approx && <span className="tile-approx">≈</span>}
                {tile.value}
                {tile.unit && <span className="tile-unit">{tile.unit}</span>}
              </>
            )}
          </div>
          <div className="tile-sub">{tile.sub ?? " "}</div>
          <div className="tile-spark">
            {tile.spark && (
              <Sparkline
                rows={rows}
                dataKey={tile.spark.key}
                color={tile.spark.color}
                from={from}
                to={to}
                binary={tile.spark.binary}
                zeroBased={tile.spark.zeroBased}
                pad={tile.spark.pad}
              />
            )}
          </div>
        </div>
      ))}
    </div>
  );
}
