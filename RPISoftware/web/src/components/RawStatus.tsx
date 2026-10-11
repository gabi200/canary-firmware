import type { AnalysisLevel, NodeKind, NodeStatusDoc } from "../api/types";
import { useT, type Lang, type MsgKey, type TFn } from "../i18n";
import { fmtNumber } from "../lib/format";
import { deviceToken } from "../lib/labels";
import { leafPaths, pick, pickNum, stateLevel } from "../lib/nodes";
import { fmtDuration } from "../lib/time";
import { StatusPill } from "./StatusPill";

type Grade = (value: unknown, doc: unknown) => AnalysisLevel;

interface Field {
  path: string;
  /** Dictionary key; fields without one (unknown firmware fields) show their raw path. */
  label?: MsgKey;
  unit?: string;
  /** "token": a firmware enum value (open / closed, none / co / gas ...) shown translated. */
  fmt?: "ms" | "s" | "duration" | "led" | "token";
  /** Device thresholds shown next to the value: [caption, path]. */
  refs?: [MsgKey, string][];
  /** Colours the value (attention / danger) against the device's own thresholds. */
  grade?: Grade;
}

interface Group {
  title: MsgKey;
  /** Device-graded state shown as a pill in the group header. */
  state?: string;
  note?: MsgKey;
  fields: Field[];
}

const UG = "µg/m³";

/** Air channels: the firmware grades value >= danger as danger, >= warn as warning. */
function limits(warn: string, danger: string): Pick<Field, "refs" | "grade"> {
  return {
    refs: [
      ["ref.warn", warn],
      ["ref.danger", danger],
    ],
    grade: (v, doc) => {
      if (typeof v !== "number") return "ok";
      const d = pickNum(doc, danger);
      const w = pickNum(doc, warn);
      return d != null && v >= d ? "danger" : w != null && v >= w ? "attention" : "ok";
    },
  };
}

/** Colours a boolean when it holds the unwanted value. */
const flag =
  (bad: boolean, level: AnalysisLevel = "attention"): Grade =>
  (v) =>
    v === bad ? level : "ok";

const byState: Grade = (v) => stateLevel(v);

const DEVICE: Field[] = [
  { path: "device.name", label: "raw.name" },
  { path: "device.firmware", label: "raw.firmware" },
  { path: "uptime_ms", label: "raw.uptime", fmt: "duration" },
];

const NETWORK: Group = {
  title: "raw.groupNetwork",
  fields: [
    { path: "wifi.connected", label: "raw.wifiConnected", grade: flag(false) },
    {
      path: "wifi.rssi",
      label: "raw.wifiRssi",
      unit: "dBm",
      grade: (v) => (typeof v === "number" && v < -80 ? "attention" : "ok"),
    },
    { path: "mqtt.enabled", label: "raw.mqttEnabled" },
    { path: "mqtt.connected", label: "raw.mqttConnected", grade: flag(false) },
    { path: "ota.in_progress", label: "raw.otaInProgress" },
  ],
};

const AIR: Group[] = [
  {
    title: "raw.groupDevice",
    fields: [...DEVICE, { path: "warmup_remaining_seconds", label: "raw.warmupLeft", fmt: "s" }],
  },
  {
    title: "sensor.co",
    state: "co.state",
    fields: [
      { path: "co.ppm", label: "metric.co", unit: "ppm", ...limits("co.warn_ppm", "co.danger_ppm") },
      { path: "co.peak_ppm", label: "raw.peak", unit: "ppm" },
      { path: "co.valid", label: "raw.valid", grade: flag(false) },
      { path: "co.age_ms", label: "raw.age", fmt: "ms" },
    ],
  },
  {
    title: "chart.gasMq5",
    state: "gas.state",
    note: "raw.gasNote",
    fields: [
      { path: "gas.adc", label: "metric.gas", unit: "ADC", ...limits("gas.warn_adc", "gas.danger_adc") },
      { path: "gas.peak_adc", label: "raw.peak", unit: "ADC" },
    ],
  },
  {
    title: "chart.particulates",
    state: "particulate.state",
    fields: [
      { path: "particulate.pm1_0", label: "metric.pm1", unit: UG },
      {
        path: "particulate.pm2_5",
        label: "metric.pm25",
        unit: UG,
        ...limits("particulate.warn_pm2_5", "particulate.danger_pm2_5"),
      },
      {
        path: "particulate.pm10",
        label: "metric.pm10",
        unit: UG,
        ...limits("particulate.warn_pm10", "particulate.danger_pm10"),
      },
      { path: "particulate.peak_pm2_5", label: "raw.peakPm25", unit: UG },
      { path: "particulate.peak_pm10", label: "raw.peakPm10", unit: UG },
      { path: "particulate.valid", label: "raw.valid", grade: flag(false) },
      { path: "particulate.age_ms", label: "raw.age", fmt: "ms" },
    ],
  },
  {
    title: "raw.groupClimate",
    fields: [
      { path: "climate.temperature_c", label: "metric.temperature", unit: "°C" },
      { path: "climate.humidity_percent", label: "metric.humidity", unit: "%RH" },
      { path: "climate.valid", label: "raw.valid", grade: flag(false) },
      { path: "climate.age_ms", label: "raw.age", fmt: "ms" },
    ],
  },
  {
    title: "raw.groupPresence",
    fields: [
      { path: "presence.detected", label: "raw.detected" },
      { path: "presence.moving", label: "raw.moving" },
      { path: "presence.stationary", label: "raw.stationary" },
      { path: "presence.moving_distance_cm", label: "raw.movingTarget", unit: "cm" },
      { path: "presence.moving_energy", label: "raw.movingEnergy" },
      { path: "presence.stationary_distance_cm", label: "raw.stationaryTarget", unit: "cm" },
      { path: "presence.stationary_energy", label: "raw.stationaryEnergy" },
      { path: "presence.detection_distance_cm", label: "raw.detectionDistance", unit: "cm" },
      { path: "presence.valid", label: "raw.valid", grade: flag(false) },
      { path: "presence.age_ms", label: "raw.age", fmt: "ms" },
    ],
  },
  {
    title: "raw.groupAlarmLed",
    state: "alarm.state",
    fields: [
      { path: "alarm.hazard", label: "raw.hazard", fmt: "token" },
      { path: "alarm.sounding", label: "raw.sounding", grade: flag(true, "danger") },
      { path: "alarm.silence_remaining_seconds", label: "raw.silenceLeft", fmt: "s" },
      { path: "alarm.self_test", label: "raw.selfTest" },
      { path: "alarm.led_color", label: "raw.ledColour", fmt: "led" },
      { path: "alarm.led_on", label: "raw.ledOn" },
    ],
  },
  NETWORK,
];

const WATER: Group[] = [
  { title: "raw.groupDevice", fields: DEVICE },
  {
    title: "chart.leakSensor",
    state: "sensor.state",
    fields: [
      {
        path: "sensor.adc",
        label: "metric.sensor",
        unit: "ADC",
        refs: [
          ["ref.wet", "sensor.wet_threshold"],
          ["ref.dry", "sensor.dry_threshold"],
        ],
        // wet at >= wet_threshold, dry at <= dry_threshold, holds its state in between
        grade: (v, doc) => {
          if (typeof v !== "number") return "ok";
          const wet = pickNum(doc, "sensor.wet_threshold");
          const dry = pickNum(doc, "sensor.dry_threshold");
          return wet != null && v >= wet ? "danger" : dry != null && v > dry ? "attention" : "ok";
        },
      },
      { path: "sensor.initialized", label: "raw.initialized", grade: flag(false) },
    ],
  },
  {
    title: "chart.leakLatch",
    fields: [{ path: "leak_latched", label: "raw.leakLatched", grade: flag(true) }],
  },
  {
    title: "raw.groupValve",
    fields: [
      { path: "valve.requested", label: "raw.requested", grade: byState, fmt: "token" },
      { path: "valve.applied", label: "raw.applied", grade: byState, fmt: "token" },
      { path: "valve.relay_active", label: "raw.relayActive" },
    ],
  },
  {
    title: "raw.groupAlarm",
    state: "alarm.state",
    fields: [
      { path: "alarm.sounding", label: "raw.sounding", grade: flag(true, "danger") },
      { path: "alarm.remaining_seconds", label: "raw.timeLeft", fmt: "s" },
    ],
  },
  NETWORK,
];

const GROUPS: Record<NodeKind, Group[]> = { air: AIR, water: WATER };

const LED_CSS: Record<string, string> = {
  green: "#2ea043",
  blue: "#2f81f7",
  cyan: "#39c5cf",
  magenta: "#db61a2",
  orange: "#f0883e",
  red: "#f85149",
  white: "#e6edf3",
};

function fmtValue(v: unknown, fmt: Field["fmt"], t: TFn, lang: Lang): string {
  if (v === undefined || v === null) return "—";
  if (typeof v === "boolean") return v ? t("common.yes") : t("common.no");
  if (typeof v === "number") {
    if (fmt === "duration") return fmtDuration(v, lang);
    if (fmt === "s") return fmtDuration(v * 1000, lang);
    if (fmt === "ms") return v < 10_000 ? `${fmtNumber(v / 1000, lang, 1, true)} ${t("unit.s")}` : fmtDuration(v, lang);
    return fmtNumber(v, lang, 1);
  }
  if (typeof v === "string") return fmt === "token" || fmt === "led" ? deviceToken(v, t) : v.replace(/_/g, " ");
  return JSON.stringify(v);
}

function FieldRow({ field, doc }: { field: Field; doc: unknown }) {
  const { t, lang } = useT();
  const v = pick(doc, field.path);
  const level = v === undefined ? "ok" : (field.grade?.(v, doc) ?? "ok");
  const refs = (field.refs ?? []).flatMap(([caption, path]) => {
    const r = pickNum(doc, path);
    return r == null ? [] : [`${t(caption)} ${fmtNumber(r, lang, 1)}`];
  });
  return (
    <div className="kv">
      <span className="k">{field.label ? t(field.label) : field.path}</span>
      <span className={`v t-${level}`}>
        {field.fmt === "led" && typeof v === "string" && (
          <span className="led-swatch" style={{ background: LED_CSS[v] ?? "transparent" }} />
        )}
        {fmtValue(v, field.fmt, t, lang)}
        {field.unit && v != null && <span className="u">{field.unit}</span>}
      </span>
      {refs.length > 0 && <span className="ref">{refs.join(" · ")}</span>}
    </div>
  );
}

/** Latest raw status document, grouped the way the firmware groups it; any field the
 *  layout does not know (other firmware versions) is listed under "Other fields". A group with
 *  none of its fields in the document (e.g. presence stripped for dispatchers) is left out. */
export function RawStatus({ kind, doc, showPresence = true }: { kind: NodeKind; doc: NodeStatusDoc | null; showPresence?: boolean }) {
  const { t } = useT();
  if (!doc) return <div className="muted small">{t("raw.empty")}</div>;

  const groups = (GROUPS[kind] ?? []).filter(
    (g) =>
      (showPresence || !g.fields.some((f) => f.path.startsWith("presence."))) &&
      g.fields.some((f) => pick(doc, f.path) !== undefined),
  );
  const known = new Set(
    groups.flatMap((g) => [
      ...(g.state ? [g.state] : []),
      ...g.fields.flatMap((f) => [f.path, ...(f.refs ?? []).map(([, p]) => p)]),
    ]),
  );
  const extra = leafPaths(doc).filter((p) => !known.has(p) && (showPresence || !p.startsWith("presence.")));
  const all: Group[] = extra.length
    ? [...groups, { title: "raw.groupOther", fields: extra.map((p) => ({ path: p })) }]
    : groups;

  return (
    <>
      <div className="raw-groups">
        {all.map((g) => {
          const state = g.state ? pick(doc, g.state) : undefined;
          return (
            <div className="raw-group" key={g.title}>
              <div className="raw-group-head">
                <span>{t(g.title)}</span>
                {typeof state === "string" && (
                  <StatusPill state={stateLevel(state)} label={deviceToken(state, t)} />
                )}
              </div>
              {g.note && <div className="muted small raw-note">{t(g.note)}</div>}
              {g.fields.map((f) => (
                <FieldRow key={f.path} field={f} doc={doc} />
              ))}
            </div>
          );
        })}
      </div>
      <details className="raw-json">
        <summary>{t("raw.json")}</summary>
        <pre>{JSON.stringify(doc, null, 2)}</pre>
      </details>
    </>
  );
}
