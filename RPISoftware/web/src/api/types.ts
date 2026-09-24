export interface Token {
  access_token: string;
  token_type: string;
  role: string;
  user_id: string;
}

export interface Building {
  id: string;
  name: string;
  address: string;
  timezone: string;
}

export interface Zone {
  id: string;
  building_id: string;
  floor_id: string;
  unit_id: string;
  label: string;
  kind: string;
}

export interface Device {
  id: string;
  building_id: string;
  zone_id: string;
  sensor_type: string;
  status: string;
  fw_version: string;
  last_seen_ts: string | null;
}

export interface Reading {
  device_id: string;
  zone_id: string;
  sensor_type: string;
  value: number;
  units: string;
  edge_state: string;
  ts: string;
}

export interface Incident {
  id: string;
  building_id: string;
  primary_zone_id: string | null;
  hazard_type: string;
  severity: string;
  state: string;
  opened_ts: string;
  updated_ts: string;
  resolved_ts: string | null;
  last_value: number;
  affected_zone_ids: string[];
  est_source_zone_id: string | null;
  est_source_x: number | null;
  est_source_y: number | null;
  triangulation_confidence: number | null;
  triangulation_method: string | null;
  advisory: boolean;
  false_alarm_class: string | null;
  false_alarm_reason: string | null;
  benign_score: number | null;
}

export interface TriangulationContributor {
  device_id: string;
  zone_id: string;
  value: number;
  weight: number;
}

export interface Triangulation {
  incident_id: string;
  source_zone_id: string | null;
  source_x: number | null;
  source_y: number | null;
  confidence: number;
  method: string;
  n_contributors: number;
  airflow_applied: boolean;
  contributors: TriangulationContributor[];
}

export interface IncidentEvent {
  id: string;
  incident_id: string;
  from_state: string;
  to_state: string;
  reason: string;
  actor: string;
  ts: string;
}

export interface ZoneOccupancy {
  zone_id: string;
  persons_est: number;
}

export interface Accounting {
  incident_id: string;
  occupancy_total: number;
  accounted: number;
  unaccounted: number;
  needs_help: number;
  zones_with_people: ZoneOccupancy[];
}

export interface Occupancy {
  building_id: string;
  zones: ZoneOccupancy[];
  total: number;
}

export interface Resident {
  user_id: string;
  display_name: string;
  unit_id: string | null;
  unit_label: string | null;
  phone: string | null;
}

export interface RosterEntry extends Resident {
  status: string; // safe_outside | safe_inside | needs_help | no_response | unknown
  source: string | null;
  ts: string | null;
}

export interface Roster {
  incident_id: string;
  total: number;
  safe: number;
  needs_help: number;
  awaiting: number;
  entries: RosterEntry[];
}

export interface AssemblyPoint {
  id: string;
  building_id: string;
  label: string;
  lat: number | null;
  lon: number | null;
}

export interface EvacuationRoute {
  id: string;
  building_id: string;
  floor_id: string;
  from_zone_id: string | null;
  to_assembly_point_id: string;
  label: string;
  path: string[];
}

export interface Evacuation {
  building_id: string;
  routes: EvacuationRoute[];
  assembly_points: AssemblyPoint[];
}

export type IncidentAction = "dismiss" | "order-evacuation" | "resolve";

/** WebSocket event envelope ("incident", "checkin" or "node"; other types are ignored). */
export interface WsEvent {
  type: string;
  incident_id?: string;
  building_id: string;
  state?: string;
  hazard_type?: string;
  severity?: string;
  primary_zone_id?: string;
  est_source_zone_id?: string | null;
  triangulation_confidence?: number | null;
  title?: string;
  body?: string;
  /** checkin: the check-in status; node: the node's analysis status. */
  status?: string;
  node_id?: string;
  kind?: string;
  zone_id?: string;
  online?: boolean;
  ts?: string;
}

// --------------------------------------------------------------------------- //
// Hardware nodes (docs/HARDWARE.md): raw firmware status documents + analysis
// --------------------------------------------------------------------------- //

/** Indicator level; node / zone / building statuses never use `unknown`. */
export type AnalysisLevel = "ok" | "attention" | "danger" | "unknown";
export type AnalysisStatus = Exclude<AnalysisLevel, "unknown">;

export interface Indicator {
  key: string;
  label: string;
  level: AnalysisLevel;
  value: string;
  detail?: string | null;
  trend?: "rising" | "falling" | "stable" | null;
}

export type NodeKind = "air" | "water";

/** The hub's interpretation of one node. Never contains raw measurements. */
export interface NodeAnalysis {
  node_id: string;
  kind: NodeKind;
  name: string;
  zone_id: string;
  online: boolean;
  stale: boolean;
  last_seen_ts: string | null;
  status: AnalysisStatus;
  headline: string;
  advice: string[];
  indicators: Indicator[];
}

export interface ZoneSummary {
  zone_id: string;
  zone_label: string;
  status: AnalysisStatus;
  /** null when the zone has no air node (no presence radar). */
  occupied: boolean | null;
  nodes: NodeAnalysis[];
}

/** GET /buildings/{id}/summary — analysis only (shared with the mobile app). */
export interface BuildingSummary {
  building_id: string;
  generated_ts: string;
  status: AnalysisStatus;
  headline: string;
  nodes_total: number;
  nodes_online: number;
  active_incidents: number;
  zones: ZoneSummary[];
}

/** An air channel as graded by the device itself. */
export type ChannelState = "warmup" | "ok" | "warning" | "danger" | "fault";

interface StatusDocBase {
  device: { name: string; firmware: string };
  uptime_ms: number;
  wifi: { connected: boolean; rssi: number };
  mqtt: { enabled: boolean; connected: boolean };
  ota: { in_progress: boolean };
}

/** ESP32-S3 air node (`air_sensor/StatusJson.cpp`). No wall clock: the hub timestamps it. */
export interface AirStatusDoc extends StatusDocBase {
  warmup_remaining_seconds: number;
  co: {
    ppm: number;
    peak_ppm: number;
    state: ChannelState;
    warn_ppm: number;
    danger_ppm: number;
    valid: boolean;
    age_ms: number;
  };
  /** `adc` is a raw, uncalibrated MQ5 ADC count (0-4095), not ppm. */
  gas: { adc: number; peak_adc: number; state: ChannelState; warn_adc: number; danger_adc: number };
  particulate: {
    pm1_0: number;
    pm2_5: number;
    pm10: number;
    peak_pm2_5: number;
    peak_pm10: number;
    state: ChannelState;
    warn_pm2_5: number;
    danger_pm2_5: number;
    warn_pm10: number;
    danger_pm10: number;
    valid: boolean;
    age_ms: number;
  };
  climate: { temperature_c: number; humidity_percent: number; valid: boolean; age_ms: number };
  presence: {
    detected: boolean;
    moving: boolean;
    stationary: boolean;
    moving_distance_cm: number;
    moving_energy: number;
    stationary_distance_cm: number;
    stationary_energy: number;
    detection_distance_cm: number;
    valid: boolean;
    age_ms: number;
  };
  alarm: {
    state: "inactive" | "warning" | "sounding" | "silenced";
    hazard: "none" | "co" | "gas" | "particulate";
    sounding: boolean;
    silence_remaining_seconds: number;
    self_test: boolean;
    led_color: string;
    led_on: boolean;
  };
}

/** ESP32-C3 water leak + valve node (`water_sensor/StatusJson.cpp`). */
export interface WaterStatusDoc extends StatusDocBase {
  sensor: {
    adc: number;
    initialized: boolean;
    state: "uninitialized" | "dry" | "wet";
    wet_threshold: number;
    dry_threshold: number;
  };
  leak_latched: boolean;
  valve: { requested: "open" | "closed"; applied: "open" | "closed"; relay_active: boolean };
  alarm: {
    state: "inactive" | "sounding" | "silenced" | "timed_out";
    sounding: boolean;
    remaining_seconds: number;
  };
}

/** Verbatim firmware document; other firmware versions may add or omit fields. */
export type NodeStatusDoc = AirStatusDoc | WaterStatusDoc;

/** GET /buildings/{id}/nodes — one physical device: raw status + analysis. */
export interface NodeOut {
  id: string;
  kind: NodeKind;
  mqtt_base: string;
  name: string;
  firmware: string | null;
  building_id: string;
  zone_id: string;
  online: boolean;
  last_seen_ts: string | null;
  boot_epoch: number;
  /** Latest raw status document, or null before the first one. */
  status: NodeStatusDoc | null;
  analysis: NodeAnalysis;
}

/** PATCH /nodes/{id} body. */
export interface NodePatch {
  zone_id?: string;
  name?: string;
}

/** GET /nodes/{id}/history — dotted field paths into the raw document; booleans are 0/1,
 *  missing values null (a path to a text field yields the text). */
export interface NodeHistory {
  node_id: string;
  minutes: number;
  fields: string[];
  points: { ts: string; values: Record<string, number | string | null> }[];
}
