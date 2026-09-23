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

/** WebSocket event envelope ("incident" or "checkin"). */
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
  status?: string;
  ts?: string;
}
