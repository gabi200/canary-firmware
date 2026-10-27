import { keepPreviousData, useMutation, useQueries, useQuery, useQueryClient } from "@tanstack/react-query";

import { useAuth } from "../auth/AuthContext";
import { useT } from "../i18n";
import { canSeeCluster } from "../lib/cluster";
import { api } from "./client";
import type {
  Accounting,
  Building,
  BuildingMotion,
  BuildingNormal,
  BuildingSummary,
  ClusterStatus,
  Device,
  Evacuation,
  Incident,
  IncidentAction,
  IncidentBrief,
  IncidentEvent,
  Escalation,
  EvidenceTimeline,
  FusionExplanation,
  NodeHistory,
  NodeOut,
  NodePatch,
  Occupancy,
  Reading,
  Resident,
  Roster,
  SensorTrust,
  Scenario,
  Triangulation,
  TriangulationHistory,
  WaterImpact,
  Zone,
} from "./types";

function useCtx() {
  const { token, buildingId } = useAuth();
  return { token, buildingId };
}

export function useBuilding() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["building", buildingId],
    queryFn: () => api.get<Building>(`/api/v1/buildings/${buildingId}`, token),
  });
}

export function useZones() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["zones", buildingId],
    queryFn: () => api.get<Zone[]>(`/api/v1/buildings/${buildingId}/zones`, token),
  });
}

export function useDevices() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["devices", buildingId],
    queryFn: () => api.get<Device[]>(`/api/v1/buildings/${buildingId}/devices`, token),
  });
}

export function useReadings(sensorType?: string, limit = 300) {
  const { token, buildingId } = useCtx();
  const qs = new URLSearchParams({ limit: String(limit) });
  if (sensorType) qs.set("sensor_type", sensorType);
  return useQuery({
    queryKey: ["readings", buildingId, sensorType ?? "all", limit],
    queryFn: () => api.get<Reading[]>(`/api/v1/buildings/${buildingId}/readings?${qs}`, token),
    refetchInterval: 8_000,
  });
}

export function useIncidents(active = false) {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["incidents", buildingId, active],
    queryFn: () =>
      api.get<Incident[]>(`/api/v1/buildings/${buildingId}/incidents?active=${active}`, token),
    refetchInterval: 10_000,
  });
}

export function useIncidentEvents(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["events", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<IncidentEvent[]>(`/api/v1/incidents/${incidentId}/events`, token),
  });
}

export function useAccounting(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["accounting", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<Accounting>(`/api/v1/incidents/${incidentId}/accounting`, token),
    refetchInterval: 5_000,
  });
}

export function useTriangulation(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["triangulation", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<Triangulation>(`/api/v1/incidents/${incidentId}/triangulation`, token),
    refetchInterval: 6_000,
  });
}

/** Advisory fusion explanation, recomputed independently of the stored incident score. */
export function useFusionExplanation(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["fusion", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<FusionExplanation>(`/api/v1/incidents/${incidentId}/fusion`, token),
    refetchInterval: 6_000,
    retry: false,
  });
}

/** Observed sequence of an incident from stored rows (404 on older backends -> nothing shown). */
export function useEvidenceTimeline(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["evidenceTimeline", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<EvidenceTimeline>(`/api/v1/incidents/${incidentId}/evidence-timeline`, token),
    refetchInterval: 15_000,
    retry: false,
  });
}

/** Stored triangulation estimates of an incident, oldest first (404 on older backends: the
 *  caller falls back to the current estimate). */
export function useTriangulationHistory(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["triangulationHistory", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<TriangulationHistory>(`/api/v1/incidents/${incidentId}/triangulation/history`, token),
    refetchInterval: 30_000,
    retry: false,
  });
}

/** Deliveries of an incident to external dispatch (ARC); 404 on older backends -> nothing shown. */
export function useEscalations(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["escalations", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<Escalation[]>(`/api/v1/incidents/${incidentId}/escalations`, token),
    refetchInterval: 30_000,
    retry: false,
  });
}

/** Incident brief (GET /incidents/{id}/brief), made only on demand: `enabled: false`, the card's
 *  button calls `refetch()`. The AI HAT+ 2 may take up to a minute, so no retry (a failure must
 *  not start another minute-long run) and no client timeout (fetch sets none; the hub bounds the
 *  wait). Keyed by language: the text comes back in the dashboard's language. */
export function useIncidentBrief(incidentId: string | null) {
  const { token } = useCtx();
  const { lang } = useT();
  return useQuery({
    queryKey: ["brief", incidentId, lang],
    queryFn: () => api.get<IncidentBrief>(`/api/v1/incidents/${incidentId}/brief`, token),
    enabled: false,
    retry: false,
    // costly to make: keep it while the incident is being handled
    gcTime: 30 * 60_000,
  });
}

/** Units a water-leak incident may reach (managers and dispatchers). */
export function useWaterImpact(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["water-impact", incidentId],
    queryFn: () => api.get<WaterImpact>(`/api/v1/incidents/${incidentId}/water-impact`, token),
    enabled: !!incidentId,
    refetchInterval: 30_000,
    retry: false,
  });
}

/** Evacuation what-if for a set of unavailable corridors / stairs (staff; simulated graph). */
export function useEvacuationScenario(unavailable: string[]) {
  const { token } = useCtx();
  const key = [...unavailable].sort();
  return useQuery({
    queryKey: ["scenario-evacuation", key],
    queryFn: () => api.post<Scenario>(`/api/v1/scenarios/evacuation`, token, { unavailable: key }),
    placeholderData: keepPreviousData,
    retry: false,
  });
}

/** The hub's Pis and the roles each runs now (one Pi, or three redundant Pis). Asked only for
 *  the roles the hub answers; 404 on older backends. */
export function useCluster() {
  const { token, session } = useAuth();
  return useQuery({
    queryKey: ["cluster"],
    queryFn: () => api.get<ClusterStatus>(`/api/v1/cluster`, token),
    enabled: canSeeCluster(session?.role),
    refetchInterval: 10_000,
    retry: false,
  });
}

export function useOccupancy() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["occupancy", buildingId],
    queryFn: () => api.get<Occupancy>(`/api/v1/buildings/${buildingId}/occupancy`, token),
    refetchInterval: 8_000,
  });
}

/** ESPectre Wi-Fi motion per zone: staff only (dispatchers and residents get 403, don't ask). */
export function useMotion() {
  const { token, buildingId, session } = useAuth();
  return useQuery({
    queryKey: ["motion", buildingId],
    queryFn: () => api.get<BuildingMotion>(`/api/v1/buildings/${buildingId}/motion`, token),
    enabled: canSeeCluster(session?.role),
    refetchInterval: 5_000,
    retry: false,
  });
}

/** Each room against its own learned normal (managers, dispatchers, technicians). */
export function useZoneNormal() {
  const { token, buildingId, session } = useAuth();
  return useQuery({
    queryKey: ["zone-normal", buildingId],
    queryFn: () => api.get<BuildingNormal>(`/api/v1/buildings/${buildingId}/zone-normal`, token),
    enabled: !!session && session.role !== "resident",
    refetchInterval: 15_000,
    retry: false,
  });
}

/** Named residents registered to the building (the people behind the occupancy counts). */
export function useResidents() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["residents", buildingId],
    queryFn: () => api.get<Resident[]>(`/api/v1/buildings/${buildingId}/residents`, token),
  });
}

/** Per-incident resident roster: who is safe, who needs help, who is still unaccounted, plus
 *  the priority (care profile) people. Health data lives only in react-query memory and
 *  `gcTime: 0` drops it as soon as no view of an active incident uses it. */
export function useRoster(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["roster", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<Roster>(`/api/v1/incidents/${incidentId}/roster`, token),
    refetchInterval: 5_000,
    gcTime: 0,
  });
}

export function useEvacuation() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["evacuation", buildingId],
    queryFn: () => api.get<Evacuation>(`/api/v1/buildings/${buildingId}/evacuation`, token),
  });
}

export function useIncidentAction() {
  const { token } = useCtx();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ incidentId, action }: { incidentId: string; action: IncidentAction }) =>
      api.post<Incident>(`/api/v1/incidents/${incidentId}/${action}`, token),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["incidents"] });
      qc.invalidateQueries({ queryKey: ["accounting"] });
      qc.invalidateQueries({ queryKey: ["events"] });
    },
  });
}

/** Building / zone / node analysis (no raw values). Refreshed live by `node` WS events. */
export function useSummary() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["summary", buildingId],
    queryFn: () => api.get<BuildingSummary>(`/api/v1/buildings/${buildingId}/summary`, token),
    refetchInterval: 15_000,
  });
}

/** Hardware nodes: latest raw status document + analysis per physical device. */
export function useNodes() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["nodes", buildingId],
    queryFn: () => api.get<NodeOut[]>(`/api/v1/buildings/${buildingId}/nodes`, token),
    refetchInterval: 15_000,
  });
}

/** On-demand sensor drift and coverage assessment over bounded history. */
export function useSensorTrust(enabled = true) {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["sensorTrust", buildingId],
    enabled,
    queryFn: () => api.get<SensorTrust[]>(`/api/v1/buildings/${buildingId}/sensor-trust`, token),
    refetchInterval: 15_000,
    retry: false,
  });
}

/** Raw status history of one node; `fields` are dotted paths into its status document.
 *  `refetchMs`: polling interval (false to pause, e.g. while the chart is off screen);
 *  react-query also pauses it while the browser tab is hidden. */
export function useNodeHistory(
  nodeId: string,
  minutes: number,
  fields?: string[],
  refetchMs: number | false = 60_000,
) {
  const { token } = useCtx();
  const qs = new URLSearchParams({ minutes: String(minutes) });
  if (fields?.length) qs.set("fields", fields.join(","));
  return useQuery({
    queryKey: ["history", nodeId, minutes, fields?.join(",") ?? ""],
    queryFn: () =>
      api.get<NodeHistory>(`/api/v1/nodes/${encodeURIComponent(nodeId)}/history?${qs}`, token),
    // keep the previous range on screen while a newly selected one loads
    placeholderData: keepPreviousData,
    refetchInterval: refetchMs,
  });
}

/** History of several nodes over the same window (one request per node; same cache keys as
 *  useNodeHistory, so a drawer and the map share the data). */
export function useNodeHistories(
  requests: { nodeId: string; fields: string[] }[],
  minutes: number,
  refetchMs: number | false = 60_000,
) {
  const { token } = useCtx();
  return useQueries({
    queries: requests.map(({ nodeId, fields }) => {
      const qs = new URLSearchParams({ minutes: String(minutes), fields: fields.join(",") });
      return {
        queryKey: ["history", nodeId, minutes, fields.join(",")],
        queryFn: () =>
          api.get<NodeHistory>(`/api/v1/nodes/${encodeURIComponent(nodeId)}/history?${qs}`, token),
        placeholderData: keepPreviousData,
        refetchInterval: refetchMs,
      };
    }),
  });
}

/** Move (zone_id) or rename a node. Managers / admins only (backend enforces). */
export function useUpdateNode() {
  const { token, buildingId } = useCtx();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ nodeId, patch }: { nodeId: string; patch: NodePatch }) =>
      api.patch<NodeOut>(`/api/v1/nodes/${encodeURIComponent(nodeId)}`, token, patch),
    onSuccess: (updated) => {
      if (updated) {
        qc.setQueryData<NodeOut[]>(["nodes", buildingId], (old) =>
          old?.map((n) => (n.id === updated.id ? updated : n)),
        );
      }
      qc.invalidateQueries({ queryKey: ["nodes"] });
      qc.invalidateQueries({ queryKey: ["summary"] });
      // the node's per-channel devices move with it (floor plan, device health)
      qc.invalidateQueries({ queryKey: ["devices"] });
    },
  });
}

/** Demo helper: push synthetic telemetry through the same pipeline as MQTT. */
export function usePostTelemetry() {
  const { token } = useCtx();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (payload: Record<string, unknown>) =>
      api.post(`/api/v1/telemetry`, token, payload),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["incidents"] });
      qc.invalidateQueries({ queryKey: ["readings"] });
    },
  });
}
