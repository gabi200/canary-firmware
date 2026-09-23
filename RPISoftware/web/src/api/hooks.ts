import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { useAuth } from "../auth/AuthContext";
import { api } from "./client";
import type {
  Accounting,
  Building,
  Device,
  Evacuation,
  Incident,
  IncidentAction,
  IncidentEvent,
  Occupancy,
  Reading,
  Resident,
  Roster,
  Triangulation,
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

export function useOccupancy() {
  const { token, buildingId } = useCtx();
  return useQuery({
    queryKey: ["occupancy", buildingId],
    queryFn: () => api.get<Occupancy>(`/api/v1/buildings/${buildingId}/occupancy`, token),
    refetchInterval: 8_000,
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

/** Per-incident resident roster: who is safe, who needs help, who is still unaccounted. */
export function useRoster(incidentId: string | null) {
  const { token } = useCtx();
  return useQuery({
    queryKey: ["roster", incidentId],
    enabled: !!incidentId,
    queryFn: () => api.get<Roster>(`/api/v1/incidents/${incidentId}/roster`, token),
    refetchInterval: 5_000,
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
