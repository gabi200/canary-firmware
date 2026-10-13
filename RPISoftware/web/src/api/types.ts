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
  /** Position in the building (metres, arbitrary origin): the coordinates triangulation uses. */
  pos_x?: number | null;
  pos_y?: number | null;
  /** Building labels of the zone's unit and floor ("Ap. 12", "Etaj 3"), when the backend sends them. */
  unit_label?: string | null;
  floor_label?: string | null;
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

export interface Signature {
  label: string;
  confidence: number;
  evidence: string[];
  shadow_label: string | null;
  shadow_confidence: number | null;
  model_version: string | null;
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
  signature: Signature | null;
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

/** One stored triangulation estimate (GET /incidents/{id}/triangulation/history). */
export interface TriangulationSnapshot extends Omit<Triangulation, "incident_id"> {
  ts: string;
}

export interface TriangulationHistory {
  incident_id: string;
  snapshots: TriangulationSnapshot[];
}

/** Delivery of an incident to an external dispatcher (GET /incidents/{id}/escalations). */
export interface Escalation {
  event_id: string;
  state: string;
  attempts: number;
  last_status: string | null;
  delivered: boolean;
  ts: string;
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
  /** Care-profile people not yet confirmed safe (absent on older backends). */
  priority_awaiting?: number;
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
  /** the resident's answer to "Where are you now?" (home | building | outside); absent: not answered */
  location?: string | null;
}

export interface Roster {
  incident_id: string;
  total: number;
  safe: number;
  needs_help: number;
  awaiting: number;
  entries: RosterEntry[];
  /** Care profiles, most urgent first. Health data (GDPR art. 9): the backend returns it only
   *  while the incident is active and audits every read; empty otherwise. Optional so an
   *  older backend without care profiles still works. */
  priority?: PriorityPerson[];
  /** Priority people not yet confirmed safe. */
  priority_awaiting?: number;
}

/** Special-needs codes a resident can register (unknown future codes render as text). */
export type CareNeed =
  | "reduced_mobility"
  | "wheelchair"
  | "bedridden"
  | "hearing_impaired"
  | "visually_impaired"
  | "medical_device"
  | "young_child"
  | "pet";

export type PriorityStatus = "needs_help" | "no_response" | "unknown" | "safe_inside" | "safe_outside";

/** A person who may not be able to evacuate alone (care profile), with their live status. */
export interface PriorityPerson {
  care_profile_id: string;
  display_name: string;
  unit_id: string | null;
  unit_label: string | null;
  floor_label: string | null;
  needs: (CareNeed | string)[];
  note: string | null;
  status: PriorityStatus;
  status_ts: string | null;
  contact_name: string | null;
  contact_phone: string | null;
}

export interface AssemblyPoint {
  id: string;
  building_id: string;
  label: string;
  lat: number | null;
  lon: number | null;
}

export interface Waypoint {
  id: string;
  label: string;
  kind: string;
  hint: string;
}

export interface EvacuationRoute {
  id: string;
  building_id: string;
  floor_id: string;
  from_zone_id: string | null;
  to_assembly_point_id: string;
  label: string;
  /** Ordered waypoint ids (zones, stairwells, exits, the assembly point). */
  path: string[];
  waypoints?: Waypoint[];
}

export interface Evacuation {
  building_id: string;
  routes: EvacuationRoute[];
  assembly_points: AssemblyPoint[];
}

export type IncidentAction = "dismiss" | "order-evacuation" | "resolve";

/** WebSocket event envelope ("incident", "checkin", "care_checkin" or "node"; other types are
 *  ignored). "care_checkin" carries no health data, only ids + status. */
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
  /** checkin: the check-in status; node: the node's analysis status; command_result:
   *  accepted | rejected | timeout. */
  status?: string;
  node_id?: string;
  /** command_result: the command it answers, and the firmware's state / error token. */
  command_id?: string;
  command?: string;
  detail?: string | null;
  care_profile_id?: string;
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
  /** summary nodes: newest command sent to the node (hardware test), null when none */
  last_command?: CommandRecord | null;
}

export interface ZoneSummary {
  zone_id: string;
  zone_label: string;
  /** the zone's apartment, on newer hubs (the scope bar maps zones through /zones instead) */
  unit_id?: string | null;
  unit_label?: string | null;
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
  /** Newest command sent to the node (hardware test), null when none; absent on older backends. */
  last_command?: CommandRecord | null;
  /** Registered itself and not placed in a room yet (technician's "new sensors"). */
  is_new?: boolean;
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

// --------------------------------------------------------------------------- //
// Device commands (hardware test): POST/GET /nodes/{id}/commands
// --------------------------------------------------------------------------- //

/** Air: TEST (4 s self-test, buzzer + LED), SILENCE. Water: OPEN / CLOSE the valve, SILENCE. */
export type NodeCommandName = "TEST" | "SILENCE" | "OPEN" | "CLOSE";

/** `timeout`: no answer from the device within 15 s (the backend computes it on read). */
export type CommandStatus = "sent" | "accepted" | "rejected" | "timeout";

/** 202 answer of POST /nodes/{id}/commands. */
export interface CommandAck {
  command_id: string;
  node_id: string;
  command: NodeCommandName;
  status: "sent";
  sent_ts: string;
}

/** One command of GET /nodes/{id}/commands (newest first) and NodeOut.last_command. */
export interface CommandRecord {
  command_id: string;
  command: NodeCommandName | string;
  status: CommandStatus | string;
  /** firmware token: `state` when accepted (self_test, silenced, open, closed), `error` when not */
  detail: string | null;
  requested_by_name: string | null;
  sent_ts: string;
  result_ts: string | null;
}

// --------------------------------------------------------------------------- //
// Administration (/admin/...): accounts, floors, apartments, rooms
// --------------------------------------------------------------------------- //

export interface AdminUnitRef {
  unit_id: string;
  unit_label: string;
}

export interface AdminUser {
  user_id: string;
  username: string;
  display_name: string;
  role: string;
  phone: string | null;
  email: string | null;
  active: boolean;
  units: AdminUnitRef[];
}

export interface AdminUserCreate {
  username: string;
  display_name: string;
  role: string;
  phone?: string;
  email?: string;
  unit_ids?: string[];
}

export type AdminUserPatch = Partial<{
  display_name: string;
  role: string;
  phone: string;
  email: string;
  unit_ids: string[];
  active: boolean;
}>;

export interface AdminFloor {
  floor_id: string;
  label: string;
  level: number;
}

export type UnitKind = "residential" | "common";

export interface AdminUnit {
  unit_id: string;
  label: string;
  floor_id: string;
  floor_label: string;
  kind: UnitKind | string;
  /** number of residents linked to the unit (a list on some backends) */
  residents: number | unknown[];
}

export interface AdminZoneNode {
  node_id: string;
  name: string;
  kind: NodeKind;
  online: boolean;
  status: AnalysisStatus | string;
}

export interface AdminZone {
  zone_id: string;
  label: string;
  kind: string;
  unit_id: string;
  unit_label: string | null;
  floor_id: string;
  floor_label: string | null;
  /** metres, arbitrary origin (the coordinates triangulation uses) */
  pos_x: number | null;
  pos_y: number | null;
  nodes: AdminZoneNode[];
}

export interface AdminZoneCreate {
  label: string;
  kind: string;
  unit_id: string;
  pos_x: number;
  pos_y: number;
}

export type AdminZonePatch = Partial<AdminZoneCreate>;

// --------------------------------------------------------------------------- //
// Hub Pis (GET /cluster): one Pi, or three redundant Pis; incident brief
// --------------------------------------------------------------------------- //

/** What a hub Pi can run: web = holds the hub address (the sensors' MQTT host, the dashboard
 *  and app URL), processing = the sensor pipeline (ingestion -> detection -> incidents ->
 *  notifications), ai = AI tasks (triangulation, incident brief). */
export type ClusterRole = "web" | "processing" | "ai";

/** The AI HAT+ 2 LLM server (hailo-ollama) of a Pi. */
export interface ClusterAccelerator {
  kind: string;
  online: boolean;
  model: string | null;
}

export interface ClusterNode {
  /** processing | web | ai (= its home role); "hub" in single mode */
  name: string;
  /** null in single mode */
  ip: string | null;
  /** heard from within the last 10 s */
  alive: boolean;
  last_seen: string | null;
  /** what it runs now */
  roles: (ClusterRole | string)[];
  /** the role it was set up for; null in single mode */
  home_role: ClusterRole | string | null;
  /** holds the hub address (null in single mode) */
  vip: boolean | null;
  /** null: no AI HAT+ 2 configured on that Pi */
  accelerator: ClusterAccelerator | null;
  /** This Pi's clock minus the database's, seconds (null: down, or an older hub). */
  clock_skew_s?: number | null;
}

/** GET /cluster (system_admin, hoa_manager, technician). */
export interface ClusterStatus {
  mode: "single" | "triple";
  /** the Pi that answered */
  node: string;
  /** the hub address sensors, dashboard and app use (null in single mode) */
  vip: string | null;
  /** null: no Pi processes sensor data (critical) */
  processing_node: string | null;
  ai_node: string | null;
  /** a Pi is down, a role runs away from its home Pi, or nobody processes */
  degraded: boolean;
  nodes: ClusterNode[];
}

/** GET /incidents/{id}/brief: a short summary written from database facts only (no names,
 *  notes or phone numbers), in the request's language. */
export interface IncidentBrief {
  incident_id: string;
  text: string;
  /** llm: written by the AI HAT+ 2; template: the fixed fallback */
  source: "llm" | "template";
  model: string | null;
  /** the Pi that wrote it */
  node: string;
  generated_ts: string;
}
