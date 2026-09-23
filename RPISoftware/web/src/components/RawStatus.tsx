import type { AnalysisLevel, NodeKind, NodeStatusDoc } from "../api/types";
import { fmtNum, leafPaths, pick, pickNum, stateLevel } from "../lib/nodes";
import { fmtDuration } from "../lib/time";
import { StatusPill } from "./StatusPill";

type Grade = (value: unknown, doc: unknown) => AnalysisLevel;

interface Field {
  path: string;
  label: string;
  unit?: string;
  fmt?: "ms" | "s" | "duration" | "led";
  /** Device thresholds shown next to the value: [caption, path]. */
  refs?: [string, string][];
  /** Colours the value (attention / danger) against the device's own thresholds. */
  grade?: Grade;
}

interface Group {
  title: string;
  /** Device-graded state shown as a pill in the group header. */
  state?: string;
  note?: string;
  fields: Field[];
}

const UG = "µg/m³";

/** Air channels: the firmware grades value >= danger as danger, >= warn as warning. */
function limits(warn: string, danger: string): Pick<Field, "refs" | "grade"> {
  return {
    refs: [
      ["warn", warn],
      ["danger", danger],
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
  { path: "device.name", label: "Name" },
  { path: "device.firmware", label: "Firmware" },
  { path: "uptime_ms", label: "Uptime", fmt: "duration" },
];

const NETWORK: Group = {
  title: "Wi-Fi / MQTT / OTA",
  fields: [
    { path: "wifi.connected", label: "Wi-Fi connected", grade: flag(false) },
    {
      path: "wifi.rssi",
      label: "Wi-Fi RSSI",
      unit: "dBm",
      grade: (v) => (typeof v === "number" && v < -80 ? "attention" : "ok"),
    },
    { path: "mqtt.enabled", label: "MQTT enabled" },
    { path: "mqtt.connected", label: "MQTT connected", grade: flag(false) },
    { path: "ota.in_progress", label: "OTA in progress" },
  ],
};

const AIR: Group[] = [
  {
    title: "Device",
    fields: [...DEVICE, { path: "warmup_remaining_seconds", label: "Warm-up left", fmt: "s" }],
  },
  {
    title: "Carbon monoxide",
    state: "co.state",
    fields: [
      { path: "co.ppm", label: "CO", unit: "ppm", ...limits("co.warn_ppm", "co.danger_ppm") },
      { path: "co.peak_ppm", label: "Peak", unit: "ppm" },
      { path: "co.valid", label: "Valid", grade: flag(false) },
      { path: "co.age_ms", label: "Age", fmt: "ms" },
    ],
  },
  {
    title: "Combustible gas (MQ5)",
    state: "gas.state",
    note: "Raw ADC count (0–4095), not ppm",
    fields: [
      { path: "gas.adc", label: "Gas", unit: "ADC", ...limits("gas.warn_adc", "gas.danger_adc") },
      { path: "gas.peak_adc", label: "Peak", unit: "ADC" },
    ],
  },
  {
    title: "Particulates",
    state: "particulate.state",
    fields: [
      { path: "particulate.pm1_0", label: "PM1.0", unit: UG },
      {
        path: "particulate.pm2_5",
        label: "PM2.5",
        unit: UG,
        ...limits("particulate.warn_pm2_5", "particulate.danger_pm2_5"),
      },
      {
        path: "particulate.pm10",
        label: "PM10",
        unit: UG,
        ...limits("particulate.warn_pm10", "particulate.danger_pm10"),
      },
      { path: "particulate.peak_pm2_5", label: "Peak PM2.5", unit: UG },
      { path: "particulate.peak_pm10", label: "Peak PM10", unit: UG },
      { path: "particulate.valid", label: "Valid", grade: flag(false) },
      { path: "particulate.age_ms", label: "Age", fmt: "ms" },
    ],
  },
  {
    title: "Climate",
    fields: [
      { path: "climate.temperature_c", label: "Temperature", unit: "°C" },
      { path: "climate.humidity_percent", label: "Humidity", unit: "%RH" },
      { path: "climate.valid", label: "Valid", grade: flag(false) },
      { path: "climate.age_ms", label: "Age", fmt: "ms" },
    ],
  },
  {
    title: "Presence (LD2410 radar)",
    fields: [
      { path: "presence.detected", label: "Detected" },
      { path: "presence.moving", label: "Moving" },
      { path: "presence.stationary", label: "Stationary" },
      { path: "presence.moving_distance_cm", label: "Moving target", unit: "cm" },
      { path: "presence.moving_energy", label: "Moving energy" },
      { path: "presence.stationary_distance_cm", label: "Stationary target", unit: "cm" },
      { path: "presence.stationary_energy", label: "Stationary energy" },
      { path: "presence.detection_distance_cm", label: "Detection distance", unit: "cm" },
      { path: "presence.valid", label: "Valid", grade: flag(false) },
      { path: "presence.age_ms", label: "Age", fmt: "ms" },
    ],
  },
  {
    title: "Alarm / LED",
    state: "alarm.state",
    fields: [
      { path: "alarm.hazard", label: "Hazard" },
      { path: "alarm.sounding", label: "Sounding", grade: flag(true, "danger") },
      { path: "alarm.silence_remaining_seconds", label: "Silence left", fmt: "s" },
      { path: "alarm.self_test", label: "Self-test" },
      { path: "alarm.led_color", label: "LED colour", fmt: "led" },
      { path: "alarm.led_on", label: "LED on" },
    ],
  },
  NETWORK,
];

const WATER: Group[] = [
  { title: "Device", fields: DEVICE },
  {
    title: "Leak sensor",
    state: "sensor.state",
    fields: [
      {
        path: "sensor.adc",
        label: "Sensor",
        unit: "ADC",
        refs: [
          ["wet ≥", "sensor.wet_threshold"],
          ["dry ≤", "sensor.dry_threshold"],
        ],
        // wet at >= wet_threshold, dry at <= dry_threshold, holds its state in between
        grade: (v, doc) => {
          if (typeof v !== "number") return "ok";
          const wet = pickNum(doc, "sensor.wet_threshold");
          const dry = pickNum(doc, "sensor.dry_threshold");
          return wet != null && v >= wet ? "danger" : dry != null && v > dry ? "attention" : "ok";
        },
      },
      { path: "sensor.initialized", label: "Initialized", grade: flag(false) },
    ],
  },
  {
    title: "Leak latch",
    fields: [{ path: "leak_latched", label: "Leak latched", grade: flag(true) }],
  },
  {
    title: "Valve",
    fields: [
      { path: "valve.requested", label: "Requested", grade: byState },
      { path: "valve.applied", label: "Applied", grade: byState },
      { path: "valve.relay_active", label: "Relay active" },
    ],
  },
  {
    title: "Alarm",
    state: "alarm.state",
    fields: [
      { path: "alarm.sounding", label: "Sounding", grade: flag(true, "danger") },
      { path: "alarm.remaining_seconds", label: "Time left", fmt: "s" },
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

function fmtValue(v: unknown, fmt?: Field["fmt"]): string {
  if (v === undefined || v === null) return "—";
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (typeof v === "number") {
    if (fmt === "duration") return fmtDuration(v);
    if (fmt === "s") return fmtDuration(v * 1000);
    if (fmt === "ms") return v < 10_000 ? `${(v / 1000).toFixed(1)} s` : fmtDuration(v);
    return fmtNum(v);
  }
  if (typeof v === "string") return v.replace(/_/g, " ");
  return JSON.stringify(v);
}

function FieldRow({ field, doc }: { field: Field; doc: unknown }) {
  const v = pick(doc, field.path);
  const level = v === undefined ? "ok" : (field.grade?.(v, doc) ?? "ok");
  const refs = (field.refs ?? []).flatMap(([caption, path]) => {
    const r = pickNum(doc, path);
    return r == null ? [] : [`${caption} ${fmtNum(r)}`];
  });
  return (
    <div className="kv">
      <span className="k">{field.label}</span>
      <span className={`v t-${level}`}>
        {field.fmt === "led" && typeof v === "string" && (
          <span className="led-swatch" style={{ background: LED_CSS[v] ?? "transparent" }} />
        )}
        {fmtValue(v, field.fmt)}
        {field.unit && v != null && <span className="u">{field.unit}</span>}
      </span>
      {refs.length > 0 && <span className="ref">{refs.join(" · ")}</span>}
    </div>
  );
}

/** Latest raw status document, grouped the way the firmware groups it; any field the
 *  layout does not know (other firmware versions) is listed under "Other fields". */
export function RawStatus({ kind, doc }: { kind: NodeKind; doc: NodeStatusDoc | null }) {
  if (!doc) return <div className="muted small">No status document received yet.</div>;

  const groups = GROUPS[kind] ?? [];
  const known = new Set(
    groups.flatMap((g) => [
      ...(g.state ? [g.state] : []),
      ...g.fields.flatMap((f) => [f.path, ...(f.refs ?? []).map(([, p]) => p)]),
    ]),
  );
  const extra = leafPaths(doc).filter((p) => !known.has(p));
  const all: Group[] = extra.length
    ? [...groups, { title: "Other fields", fields: extra.map((p) => ({ path: p, label: p })) }]
    : groups;

  return (
    <>
      <div className="raw-groups">
        {all.map((g) => {
          const state = g.state ? pick(doc, g.state) : undefined;
          return (
            <div className="raw-group" key={g.title}>
              <div className="raw-group-head">
                <span>{g.title}</span>
                {typeof state === "string" && (
                  <StatusPill state={stateLevel(state)} label={state} />
                )}
              </div>
              {g.note && <div className="muted small raw-note">{g.note}</div>}
              {g.fields.map((f) => (
                <FieldRow key={f.path} field={f} doc={doc} />
              ))}
            </div>
          );
        })}
      </div>
      <details className="raw-json">
        <summary>Verbatim JSON</summary>
        <pre>{JSON.stringify(doc, null, 2)}</pre>
      </details>
    </>
  );
}
